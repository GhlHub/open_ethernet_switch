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
// Two clock domains: the GEM FIFO interface (gem_clk) needs to sustain
// roughly one byte per 8ns (~125MHz-class throughput at 8-bit width) to
// keep up with full gigabit -- fixed hardware timing, can't be reclocked.
// The fabric side (clk) runs at the switch's own 62.5MHz/16-bit
// convention. rtl/common/async_fifo.sv (Gray-code CDC FIFO) crosses that
// boundary; a small packer state machine on the clk side then combines
// pairs of bytes into 16-bit words (tkeep=2'b01 for a trailing single
// byte, i.e. an odd-length frame) before presenting them as AXI4-Stream.
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
  parameter int FIFO_DEPTH = 64
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

  localparam int ENTRY_W = 8 + 1 + 1; // data + eop + err

  // ---- GEM-side (gem_clk): push into the async FIFO ----
  //
  // Everything in this block is gem_clk-domain only: fifo_full is the async
  // FIFO's write-side flag. (The FIFO's empty flag belongs to the fabric
  // clock and must NOT be used here -- an earlier version cleared the
  // overflow flag from it, an unsynchronized clock-domain crossing.)
  //
  // When bytes of a frame have to be thrown away (FIFO full, or flush) after
  // part of that frame is already in the FIFO, the FIFO would be left with a
  // frame that has no end marker, and the fabric-side packer would glue the
  // next frame onto it. So an aborted frame is closed with one synthetic
  // {err=1, eop=1} entry (data 0x00) as soon as the FIFO has room, and the
  // rest of that frame is discarded up to the next SOP. The synthetic entry
  // reaches ingress_port_wr.sv as a frame with tuser (bad frame) set, which
  // it already drops.
  logic discard_q;   // throwing bytes away until the next SOP
  logic in_frame_q;  // a non-final byte of the current frame is in the FIFO
  logic abort_q;     // owe the FIFO a synthetic err+eop entry

  // an SOP byte always ends a discard, and is itself kept
  wire sop_now     = rx_w_wr_i && rx_w_sop_i;
  wire discard_eff = discard_q && !sop_now;

  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en, fifo_full;

  wire term_push = abort_q && !fifo_full;
  wire byte_push = rx_w_wr_i && !discard_eff && !fifo_full && !term_push;
  wire byte_drop = rx_w_wr_i && !discard_eff && (fifo_full || term_push);

  assign fifo_wr_en   = term_push || byte_push;
  assign fifo_wr_data = term_push ? {1'b1, 1'b1, 8'h00}
                                  : {rx_w_err_i, rx_w_eop_i, rx_w_data_i};

  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      discard_q  <= 1'b0;
      in_frame_q <= 1'b0;
      abort_q    <= 1'b0;
    end else begin
      if (byte_push) in_frame_q <= !rx_w_eop_i;
      if (term_push) begin
        in_frame_q <= 1'b0;
        abort_q    <= 1'b0;
      end
      if (rx_w_flush_i) begin
        discard_q <= 1'b1;
        if (in_frame_q && !term_push) abort_q <= 1'b1;
      end else begin
        if (sop_now) discard_q <= 1'b0;
        if (byte_drop) begin
          discard_q <= 1'b1;
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
  // data. Set the cycle after a byte is dropped; cleared one cycle after
  // the GEM's own rx_w_eop for that frame, which satisfies "asserted no later
  // than one cycle after rx_w_eop". Entirely gem_clk-domain.
  logic overflow_q, frame_end_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n || rx_w_flush_i) begin
      overflow_q  <= 1'b0;
      frame_end_q <= 1'b0;
    end else begin
      frame_end_q <= rx_w_wr_i && rx_w_eop_i;
      if (byte_drop)         overflow_q <= 1'b1;
      else if (frame_end_q)  overflow_q <= 1'b0;
    end
  end
  assign rx_w_overflow_o = overflow_q;

  // ---- fabric-side (clk): pack pairs of bytes popped from the FIFO
  // into 16-bit AXI4-Stream words. async_fifo's read side is a
  // combinational peek-before-pop (rd_data_o reflects the next entry to
  // dequeue whenever !empty; asserting rd_en_i that same cycle commits
  // the pop) -- no extra registered-read wait state is needed here,
  // unlike the frame_ram pattern used elsewhere in this project. ----
  typedef enum logic {S_FIRST, S_SECOND} pk_state_t;
  pk_state_t pk_state_q;

  logic [7:0] first_byte_q;
  logic       first_err_q;

  wire       first_eop = fifo_rd_data[8];
  wire       this_err  = fifo_rd_data[9];
  wire [7:0] this_byte = fifo_rd_data[7:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pk_state_q <= S_FIRST;
    end else begin
      unique case (pk_state_q)
        S_FIRST: begin
          if (!fifo_empty && !first_eop) begin
            first_byte_q <= this_byte;
            first_err_q  <= this_err;
            pk_state_q   <= S_SECOND;
          end
          // a lone final byte (first_eop=1) is presented and popped
          // combinationally below without changing state -- see fifo_rd_en
        end
        S_SECOND: begin
          if (!fifo_empty && m_axis_tready) pk_state_q <= S_FIRST;
        end
        default: pk_state_q <= S_FIRST;
      endcase
    end
  end

  always_comb begin
    fifo_rd_en    = 1'b0;
    m_axis_tdata  = {this_byte, first_byte_q};
    m_axis_tkeep  = 2'b11;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    m_axis_tuser  = 1'b0;

    unique case (pk_state_q)
      S_FIRST: begin
        if (!fifo_empty) begin
          if (first_eop) begin
            // lone trailing byte of an odd-length frame
            m_axis_tdata  = {8'h00, this_byte};
            m_axis_tkeep  = 2'b01;
            m_axis_tvalid = 1'b1;
            m_axis_tlast  = 1'b1;
            m_axis_tuser  = this_err;
            fifo_rd_en    = m_axis_tready;
          end else begin
            // capture the first byte of a pair (mirrors the always_ff's
            // own transition condition exactly) and pop it -- nothing is
            // presented on m_axis_* yet, so there's no backpressure to
            // honor for this pop specifically.
            fifo_rd_en = 1'b1;
          end
        end
      end
      S_SECOND: begin
        if (!fifo_empty) begin
          m_axis_tdata  = {this_byte, first_byte_q};
          m_axis_tkeep  = 2'b11;
          m_axis_tlast  = first_eop; // reusing the wire: this is the *second* byte's eop here
          m_axis_tvalid = 1'b1;
          m_axis_tuser  = this_err;
          fifo_rd_en    = m_axis_tready;
        end
      end
      default: ;
    endcase
  end

endmodule
