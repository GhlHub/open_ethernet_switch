// axis_to_gem_tx_r.sv
//
// AXI4-Stream slave -> PS GEM "Transmit FIFO Interface to PL", for one PS
// GEM instance configured in FIFO Interface mode (UG1085 v2.5, Chapter 34
// "GEM Ethernet", Tables 34-1/34-2; port names match the Vivado-generated
// EMIO wrapper signals emio_enetN_tx_r_*/emio_enetN_dma_tx_* minus the
// "emio_enetN_" prefix -- see gem_rx_w_to_axis.sv for the same note).
//
// This is the direction where the GEM is about to put a frame on the
// wire, and PL is the one that actually holds the frame data -- so from
// the switch's point of view this is an EGRESS sink (a frame the switch
// fabric decided goes out this port leaves the switch here). This module
// is an AXI4-Stream SLAVE whose input plugs into egress_port_rd.sv's
// m_axis_* port (16-bit, same tdata/tkeep/tvalid/tlast convention as
// ingress_port_wr.sv's s_axis_*).
//
// Two clock domains, same rationale as gem_rx_w_to_axis.sv: the GEM side
// (gem_clk = the GEM's tx_clk) pulls one byte per ~8 ns (1 Gb/s at 8-bit
// width); the KR260 fabric side (clk) runs at 100 MHz / 16 bits. The crossing carries whole 16-bit words
// -- each accepted AXI4-Stream word is written into rtl/common/async_fifo.sv
// as one entry {eop, keep_hi, data[15:0]}, one write per fabric cycle -- and
// the 16-to-8 unpack happens on the GEM side, after the crossing. (An
// earlier version unpacked on the fabric side and pushed one byte per
// fabric cycle, half the rate the GEM pulls at.)
//
// Protocol (UG1085 Ch.34 Table 34-1 + surrounding text): this is a
// request/response PULL, not AXI-Stream valid/ready -- the GEM pulses
// tx_r_rd_i for one cycle to request the next byte, and PL must respond
// with tx_r_valid_o (+ tx_r_data_o/tx_r_sop_o/tx_r_eop_o), which "can be
// returned during the same cycle as the tx_r_rd request" or an arbitrary
// number of cycles later. tx_r_data_rdy_o gates the whole exchange.
//
// tx_r_data_rdy_o start policy: release a frame only when START_WORDS
// are buffered, or its last word has arrived (a short frame). This absorbs
// upstream stalls before allowing the GEM to pull at line rate. The current
// egress prefetch path supplies continuous words at the fabric clock rate.
// The fabric side counts words per frame and issues ONE "permit" per frame,
// as a Gray-coded event counter synchronized into gem_clk like the FIFO
// pointers; the GEM side counts frames it has finished; data_rdy is high
// while permits exceed finished frames and the FIFO is non-empty.
// FIFO_DEPTH must comfortably exceed START_WORDS.
//
// Frame content is assumed to already exclude the trailing Ethernet FCS
// -- the GEM's MAC appends its own CRC on transmit, same as it would for
// a normal DMA-sourced frame; tx_r_control_o (no-crc-append) is tied low
// accordingly. tx_r_err_o is tied low: nothing on the egress path here
// marks a frame bad after it has already been buffered (bad frames were
// dropped at ingress). tx_r_flushed_o pulses only as part of the underflow
// recovery (tx_r_err_o is never asserted).
//
// dma_tx_end_tog_i/dma_tx_status_tog_o implement the frame-complete
// acknowledgement handshake from Table 34-2, gem_clk-domain end to end
// (the GEM drives/expects both sides of this exchange in its own clock
// domain): the GEM toggles dma_tx_end_tog_i when a frame completes and
// tx_r_status_i is valid; PL must toggle dma_tx_status_tog_o back to
// acknowledge, which this module does unconditionally on the next cycle
// (tx_r_status_i itself is not otherwise consumed here).

module axis_to_gem_tx_r #(
  parameter int FIFO_DEPTH  = 256, // in 16-bit words; power of 2
  parameter int START_WORDS = 128  // words of a frame buffered before the GEM may start it
) (
  input  logic clk,      // fabric clock (100 MHz in KR260)
  input  logic rst_n,
  input  logic gem_clk,
  input  logic gem_rst_n,

  // switch egress AXI4-Stream slave, 16-bit (<- egress_port_rd.sv m_axis_*)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // GEM TX FIFO interface (gem_clk domain, GEM-driven pull request; PL responds)
  input  logic       tx_r_rd_i,
  output logic       tx_r_data_rdy_o,
  output logic       tx_r_valid_o,
  output logic [7:0] tx_r_data_o,
  output logic       tx_r_sop_o,
  output logic       tx_r_eop_o,
  output logic       tx_r_err_o,
  output logic       tx_r_underflow_o,
  output logic       tx_r_flushed_o,
  output logic       tx_r_control_o,

  // GEM TX FIFO interface status/ack (Table 34-2, gem_clk domain)
  input  logic       dma_tx_end_tog_i,
  output logic       dma_tx_status_tog_o,
  input  logic [3:0] tx_r_status_i
);

  assign tx_r_err_o       = 1'b0;
  assign tx_r_control_o   = 1'b0;

  // FIFO entry: {eop, keep_hi, data[15:0]}
  localparam int ENTRY_W = 16 + 2;
  localparam int PW = $clog2(FIFO_DEPTH) + 1; // permit counter width

  // ---- fabric side (clk): one write per accepted word ----
  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en, fifo_full;

  assign s_axis_tready = !fifo_full;
  assign fifo_wr_en    = s_axis_tvalid && !fifo_full;
  assign fifo_wr_data  = {s_axis_tlast, s_axis_tkeep[1], s_axis_tdata};

  // one permit per frame: when START_WORDS of it are written, or at its last
  // word if it is shorter than that
  localparam int WCW = $clog2(START_WORDS + 1) + 1;
  localparam logic [WCW-1:0] START_W = WCW'(START_WORDS);
  logic [WCW-1:0] words_q;
  logic           permitted_q;
  logic [PW-1:0]                  permit_bin_q, permit_gray_q;

  wire permit_now = fifo_wr_en && !permitted_q &&
                    (s_axis_tlast || (words_q + 1'b1 >= START_W));
  wire [PW-1:0] permit_bin_next  = permit_bin_q + (PW)'(permit_now);
  wire [PW-1:0] permit_gray_next = permit_bin_next ^ (permit_bin_next >> 1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      words_q       <= '0;
      permitted_q   <= 1'b0;
      permit_bin_q  <= '0;
      permit_gray_q <= '0;
    end else begin
      permit_bin_q  <= permit_bin_next;
      permit_gray_q <= permit_gray_next;
      if (fifo_wr_en) begin
        if (s_axis_tlast) begin
          words_q     <= '0;
          permitted_q <= 1'b0;
        end else begin
          if (words_q < START_W) words_q <= words_q + 1'b1;
          if (permit_now) permitted_q <= 1'b1;
        end
      end
    end
  end

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_rd_en, fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (clk),
    .wr_rst_n  (rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (gem_clk),
    .rd_rst_n  (gem_rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- GEM side (gem_clk): unpack words to bytes, pull/response ----
  //
  // permit counter, synchronized to gem_clk (Gray code: one bit changes per
  // increment, the same reasoning as the FIFO's own pointers), converted
  // back to binary for the subtraction below.
  (* ASYNC_REG = "TRUE" *) logic [PW-1:0] permit_gray_sync1, permit_gray_sync2;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      permit_gray_sync1 <= '0;
      permit_gray_sync2 <= '0;
    end else begin
      permit_gray_sync1 <= permit_gray_q;
      permit_gray_sync2 <= permit_gray_sync1;
    end
  end
  logic [PW-1:0] permit_bin_sync;
  always_comb begin
    permit_bin_sync[PW-1] = permit_gray_sync2[PW-1];
    for (int i = PW-2; i >= 0; i--) permit_bin_sync[i] = permit_bin_sync[i+1] ^ permit_gray_sync2[i];
  end
  logic [PW-1:0] done_q; // frames whose last word the GEM side has consumed
  wire frame_released = (permit_bin_sync != done_q);

  // Underflow / flush (UG1085 Ch.34 Table 34-1 and text): once the GEM starts
  // a read (tx_r_rd) it must be answered with tx_r_valid OR tx_r_underflow.
  // If the FIFO is empty during a frame (later words have not arrived yet),
  // tx_r_underflow_o answers it in the same cycle. The GEM then
  // waits for tx_r_flushed, so this module:
  //   T_DRAIN     data_rdy low; discard the rest of the frame as it arrives
  //               (up to and including its eop)
  //   T_FLUSH     tx_r_flushed_o high for one cycle, then low -- the falling
  //               edge is what tells the GEM the flush is complete
  //   T_RUN       normal; data_rdy is raised again only after the flush
  // Between frames an outstanding read instead waits for the next permit.
  // The manual's other flush cases (tx_r_err, half-duplex collisions) are not
  // produced by anything here.
  wire [15:0] word_data = fifo_rd_data[15:0];
  wire        word_keep_hi = fifo_rd_data[16];
  wire        word_eop  = fifo_rd_data[17];

  typedef enum logic [1:0] {T_RUN, T_DRAIN, T_FLUSH} tx_state_t;
  tx_state_t tx_state_q;

  logic sop_q;
  logic hi_pending_q; // low byte of the head entry sent; high byte is next
  logic read_pending_q;

  wire [7:0] byte_val = hi_pending_q ? word_data[15:8] : word_data[7:0];
  wire       byte_eop = word_eop && (hi_pending_q || !word_keep_hi);
  // the head entry is fully consumed after its last byte
  wire       entry_last_byte = hi_pending_q || !word_keep_hi;

  assign tx_r_data_rdy_o  = (tx_state_q == T_RUN) && !fifo_empty && frame_released;
  // The physical GEM can issue a trailing read on the cycle after EOP.
  // Empty BETWEEN frames is not a transmit underrun. Remember that request
  // and answer it when the next permitted frame is available. Once SOP has
  // been sent, an empty FIFO really does mean a truncated frame.
  wire read_request = tx_r_rd_i || read_pending_q;
  assign tx_r_underflow_o = (tx_state_q == T_RUN) && read_request && fifo_empty && !sop_q;
  assign tx_r_flushed_o   = (tx_state_q == T_FLUSH);

  wire drain_pop = (tx_state_q == T_DRAIN) && !fifo_empty;
  wire run_read  = (tx_state_q == T_RUN) && read_request && !fifo_empty && frame_released;

  assign fifo_rd_en   = drain_pop || (run_read && entry_last_byte);
  assign tx_r_valid_o = run_read;
  assign tx_r_data_o  = byte_val;
  assign tx_r_sop_o   = tx_r_valid_o && sop_q;
  assign tx_r_eop_o   = tx_r_valid_o && byte_eop;

  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      sop_q        <= 1'b1;
      hi_pending_q <= 1'b0;
      read_pending_q <= 1'b0;
      tx_state_q   <= T_RUN;
      done_q       <= '0;
    end else begin
      read_pending_q <= (tx_state_q == T_RUN) && read_request &&
                        !run_read && !tx_r_underflow_o;
      if (tx_r_valid_o) begin
        sop_q        <= byte_eop;
        hi_pending_q <= word_keep_hi && !hi_pending_q;
        if (byte_eop) done_q <= done_q + 1'b1;
      end
      unique case (tx_state_q)
        T_RUN: begin
          if (tx_r_underflow_o) begin
            if (sop_q) tx_state_q <= T_FLUSH;
            else       tx_state_q <= T_DRAIN;
          end
        end
        T_DRAIN: begin
          if (drain_pop && word_eop) begin
            sop_q      <= 1'b1;
            done_q     <= done_q + 1'b1;
            tx_state_q <= T_FLUSH;
          end
        end
        T_FLUSH: tx_state_q <= T_RUN;
        default: tx_state_q <= T_RUN;
      endcase
    end
  end

  // frame-complete ack: unconditionally follow dma_tx_end_tog_i one
  // cycle later (tx_r_status_i isn't otherwise consumed by this module)
  logic dma_tx_end_tog_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      dma_tx_end_tog_q   <= 1'b0;
      dma_tx_status_tog_o <= 1'b0;
    end else begin
      dma_tx_end_tog_q <= dma_tx_end_tog_i;
      if (dma_tx_end_tog_i != dma_tx_end_tog_q) dma_tx_status_tog_o <= ~dma_tx_status_tog_o;
    end
  end

endmodule
