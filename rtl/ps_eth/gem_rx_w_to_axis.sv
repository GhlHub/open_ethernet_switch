// gem_rx_w_to_axis.sv
//
// PS GEM "Receive FIFO Interface to PL" -> AXI4-Stream master, for one PS
// GEM instance configured in FIFO Interface mode (Zynq UltraScale+ TRM
// UG1085 v2.5, Chapter 34 "GEM Ethernet", Table 34-3; port names below
// match the Vivado-generated EMIO wrapper signals emio_enetN_rx_w_* from
// UG1085 Table 28-1, minus the "emio_enetN_" prefix -- reattach that
// prefix for the actual GEM instance N when wiring this at the board/top
// level).
//
// In this interface mode the GEM's MAC does the framing/CRC/PHY-side
// work, but PL supplies/consumes the actual byte stream -- so a frame
// arriving on this GEM's wire is pushed BY THE GEM INTO PL. From the
// switch's point of view that makes this GEM's "RX" side an INGRESS
// source, same as a frame arriving on any physical port: this module is
// an AXI4-Stream MASTER whose output plugs into ingress_port_wr.sv's
// s_axis_* port (rtl/dma/ingress_port_wr.sv).
//
// Two clock domains: the GEM FIFO interface (gem_clk = the GEM's rx_clk)
// pushes one byte per ~8 ns (1 Gb/s at 8-bit width) -- fixed hardware
// timing, can't be reclocked. The fabric side (clk) runs at the switch's
// 62.5 MHz / 16-bit convention, which is also exactly 1 Gb/s. The width
// conversion therefore happens on the GEM side, BEFORE the crossing: bytes
// are packed into 16-bit words in the gem_clk domain and one whole word
// (plus keep/eop/err) is written into rtl/common/async_fifo.sv per write,
// so the crossing carries 1 word per 16 ns and the fabric side reads one
// word per cycle straight onto AXI4-Stream, with no further packing. (An
// earlier version crossed byte-wide and packed on the fabric side, which
// could only drain 1 byte per fabric cycle -- half the rate the GEM pushes
// at, so a line-rate frame overflowed the FIFO after ~128 bytes.)
//
// Protocol (UG1085 Ch.34, Table 34-3 + surrounding text): the GEM pushes
// unconditionally -- rx_w_wr_i pulses with rx_w_data_i/rx_w_sop_i/
// rx_w_eop_i whenever it has a byte, with NO ready/backpressure signal
// at all. The only way to signal "PL couldn't keep up" is rx_w_overflow_o,
// which the GEM then reflects back as a bad frame (rx_w_err coincident
// with rx_w_eop, per the doc) -- so the async FIFO doubles as the elastic
// buffer absorbing ingress_port_wr.sv's ordinary brief backpressure
// (alloc-wait stalls etc.) without needing to raise overflow for that.
// rx_w_overflow_o is still asserted if the FIFO itself ever fills (for
// the rest of the affected frame, ending one cycle after its rx_w_eop --
// see the block below), which is the correctness backstop if FIFO_DEPTH
// is ever undersized for the actual downstream stall profile.
//
// rx_w_err (asserted by the GEM coincident with rx_w_eop on a bad frame
// -- short/CRC-error/etc.) maps directly onto ingress_port_wr.sv's
// s_axis_tuser bad-frame convention (carried on the final, possibly-
// partial-word transfer of the frame).
//
// rx_w_flush_i (GEM signaling "clear the RX FIFO", e.g. receive disabled
// mid-frame): on flush, it stops pushing any further bytes of the current
// (now-aborted) frame into the async FIFO until the next rx_w_sop_i, and
// closes a partly-pushed frame with a synthetic err+eop entry so the
// downstream sees a bad frame rather than a frame that never ends.
// KNOWN GAP: bytes already pushed *before* the flush arrived are still
// delivered (as part of that bad frame) -- they are not purged from the
// FIFO or from the fabric-side packer's in-progress pair.
//
// rx_w_status[44:0] (frame length / address-match / VLAN classification
// bits) is passed through as a raw, gem_rx_clk-domain-timed side output for
// a future consumer -- unlike the single-clock version of this module,
// it is NOT guaranteed to line up with m_axis_tlast's cycle any more
// (that now happens later, after crossing into the fabric clock domain);
// a future consumer needs to synchronize it independently if it starts
// actually using this signal.

module gem_rx_w_to_axis #(
  parameter int FIFO_DEPTH = 128 // in 16-bit words (256 bytes); power of 2
) (
  input  logic gem_clk,
  input  logic gem_rst_n,
  input  logic clk,      // fabric clock (62.5 MHz)
  input  logic rst_n,    // fabric reset

  // GEM RX FIFO interface (GEM-driven push, gem_clk domain)
  input  logic [7:0]  rx_w_data_i,
  input  logic        rx_w_wr_i,
  input  logic        rx_w_sop_i,
  input  logic        rx_w_eop_i,
  input  logic        rx_w_err_i,
  input  logic        rx_w_flush_i,
  input  logic [44:0] rx_w_status_i,
  output logic        rx_w_overflow_o,

  // switch ingress AXI4-Stream master, 16-bit (-> ingress_port_wr.sv s_axis_*)
  output logic [15:0] m_axis_tdata,
  output logic [1:0]  m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,
  input  logic         m_axis_tready,

  // raw passthrough of the frame's classification bits -- gem_clk-domain
  // timed, see the header note above
  output logic [44:0] rx_w_status_o
);

  // FIFO entry: {err, eop, keep_hi, data[15:0]}. keep_lo is always set (a
  // word carries at least its low byte); keep_hi is clear only for the
  // trailing single byte of an odd-length frame.
  localparam int ENTRY_W = 16 + 3;

  // ---- GEM-side (gem_clk): pack bytes into words, push into the FIFO ----
  //
  // Everything in this block is gem_clk-domain only: fifo_full is the async
  // FIFO's write-side flag. (The FIFO's empty flag belongs to the fabric
  // clock and must NOT be used here -- an earlier version cleared the
  // overflow flag from it, an unsynchronized clock-domain crossing.)
  //
  // When data has to be thrown away (FIFO full, or flush) after part of a
  // frame is already in the FIFO, the FIFO would be left with a frame that
  // has no end marker, and the next frame would be glued onto it. So an
  // aborted frame is closed with one synthetic {err=1, eop=1} entry (a
  // single 0x00 byte) as soon as the FIFO has room, and the rest of that
  // frame is discarded up to the next SOP. The synthetic entry reaches
  // ingress_port_wr.sv as a frame with tuser (bad frame) set, which it
  // already drops. A byte waiting to be paired (lo_q) belongs to the frame
  // being discarded, so it is thrown away too.
  logic       discard_q;   // throwing bytes away until the next SOP
  logic       in_frame_q;  // a non-final word of the current frame is in the FIFO
  logic       abort_q;     // owe the FIFO a synthetic err+eop entry
  logic       have_lo_q;   // first byte of a pair is waiting in lo_q
  logic [7:0] lo_q;

  // an SOP byte always ends a discard, and is itself kept
  wire sop_now     = rx_w_wr_i && rx_w_sop_i;
  wire discard_eff = discard_q && !sop_now;

  logic fifo_full;

  wire byte_in   = rx_w_wr_i && !discard_eff;
  // a byte completes a word when it is the second of a pair, or is the
  // final byte of the frame
  wire emit      = byte_in && (have_lo_q || rx_w_eop_i);
  wire term_push = abort_q && !fifo_full;
  wire word_push = emit && !fifo_full && !term_push;
  wire word_drop = emit && (fifo_full || term_push);

  wire [ENTRY_W-1:0] word_entry = {rx_w_err_i, rx_w_eop_i, have_lo_q,
                                   have_lo_q ? rx_w_data_i : 8'h00,
                                   have_lo_q ? lo_q        : rx_w_data_i};
  wire [ENTRY_W-1:0] term_entry = {1'b1, 1'b1, 1'b0, 8'h00, 8'h00};

  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en;
  assign fifo_wr_en   = term_push || word_push;
  assign fifo_wr_data = term_push ? term_entry : word_entry;

  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      discard_q  <= 1'b0;
      in_frame_q <= 1'b0;
      abort_q    <= 1'b0;
      have_lo_q  <= 1'b0;
      lo_q       <= '0;
    end else begin
      // pairing
      if (byte_in && !emit) begin
        lo_q      <= rx_w_data_i;
        have_lo_q <= 1'b1;
      end else if (emit) begin
        have_lo_q <= 1'b0;
      end
      // frame bookkeeping
      if (word_push) in_frame_q <= !rx_w_eop_i;
      if (term_push) begin
        in_frame_q <= 1'b0;
        abort_q    <= 1'b0;
      end
      if (rx_w_flush_i) begin
        discard_q <= 1'b1;
        have_lo_q <= 1'b0;
        if (in_frame_q && !term_push) abort_q <= 1'b1;
      end else begin
        if (sop_now) discard_q <= 1'b0;
        if (word_drop) begin
          discard_q <= 1'b1;
          have_lo_q <= 1'b0;
          if (in_frame_q && !term_push) abort_q <= 1'b1;
        end
      end
    end
  end

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_rd_en, fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (gem_clk),
    .wr_rst_n  (gem_rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (clk),
    .rd_rst_n  (rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // status bits: latched gem_clk-side on eop, see the header note about
  // this no longer being cycle-locked to m_axis_tlast
  logic [44:0] rx_w_status_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) rx_w_status_q <= '0;
    else if (rx_w_wr_i && rx_w_eop_i) rx_w_status_q <= rx_w_status_i;
  end
  assign rx_w_status_o = rx_w_status_q;

  // overflow (UG1085 Table 34-3 text): tells the GEM the PL FIFO dropped
  // data. Set the cycle after a word is dropped; cleared one cycle after
  // the GEM's own rx_w_eop for that frame, which satisfies "asserted no later
  // than one cycle after rx_w_eop". A word is only ever dropped on the cycle
  // its last byte arrives, so a drop on the frame's final word is seen at
  // eop+1. Entirely gem_clk-domain.
  logic overflow_q, frame_end_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n || rx_w_flush_i) begin
      overflow_q  <= 1'b0;
      frame_end_q <= 1'b0;
    end else begin
      frame_end_q <= rx_w_wr_i && rx_w_eop_i;
      if (word_drop)         overflow_q <= 1'b1;
      else if (frame_end_q)  overflow_q <= 1'b0;
    end
  end
  assign rx_w_overflow_o = overflow_q;

  // ---- fabric side (clk): the FIFO already holds whole AXI4-Stream words ----
  wire [15:0] rd_word = fifo_rd_data[15:0];
  wire        rd_keep_hi = fifo_rd_data[16];
  wire        rd_eop  = fifo_rd_data[17];
  wire        rd_err  = fifo_rd_data[18];

  assign m_axis_tvalid = !fifo_empty;
  assign m_axis_tdata  = rd_word;
  assign m_axis_tkeep  = {rd_keep_hi, 1'b1};
  assign m_axis_tlast  = rd_eop;
  assign m_axis_tuser  = rd_err && rd_eop;
  assign fifo_rd_en    = m_axis_tvalid && m_axis_tready;

endmodule
