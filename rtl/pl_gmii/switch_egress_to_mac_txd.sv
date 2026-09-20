// switch_egress_to_mac_txd.sv
//
// This switch's egress AXI4-Stream convention (16-bit, clk domain,
// 100MHz) -> open_eth_mac_1g_switch's s_axis_txd (32-bit AXI4-Stream,
// its own axis_clk domain -- 142.86MHz here, fixed by its internal packet
// buffer, not reclockable). Two clock domains. WORD-WIDE datapath (a
// byte-serial version capped each port at 0.8 Gbit/s, below the wire rate): the
// clk side writes each accepted 16-bit/tkeep word straight into
// rtl/common/async_fifo.sv as {eop, upper-byte-valid, data16}; the axis_clk
// side pops two words per 32-bit beat (a lone or final word makes a partial
// beat), presenting the beat from an output register while the next one is
// assembled. Sustained throughput: one word per cycle on the fabric side
// (1.6 Gbit/s at 100MHz) and on the MAC side (2.3 Gbit/s at 142.86MHz).
//
// s_axis_txc (the separate "TX control" stream this MAC's AXI4-Stream
// contract requires): this core doesn't actually consume s_axis_txc_
// tdata's *content* anywhere (checksum-offload insertion control, which
// this core doesn't implement) -- only the handshake matters, and
// specifically: s_axis_txd_tready stays low until one full s_axis_txc
// transfer (tvalid && tready, tlast=1) has completed, per frame. So this
// module issues exactly one dummy txc beat (content don't-care, tkeep
// all-ones, tlast=1) ahead of each frame's txd bytes, gated on the FIFO
// actually having that frame's first byte ready (this switch's store-
// and-forward design means the rest reliably follows).

module switch_egress_to_mac_txd #(
  parameter int FIFO_DEPTH = 256   // 16-bit words
) (
  input  logic clk,      // fabric clock (100 MHz)
  input  logic rst_n,
  input  logic axis_clk, // MAC's AXI4-Stream clock (its own required rate)
  input  logic axis_rst_n,

  // switch egress AXI4-Stream slave, 16-bit, clk domain
  // (<- egress_port_rd.sv m_axis_*)
  input  logic [15:0] s_axis_tdata_i,
  input  logic [1:0]  s_axis_tkeep_i,
  input  logic         s_axis_tvalid_i,
  input  logic         s_axis_tlast_i,
  output logic         s_axis_tready_o,

  // open_eth_mac_1g_switch's s_axis_txc, axis_clk domain (content
  // don't-care -- see header note; tdata/tkeep tied to fixed values)
  output logic        s_axis_txc_tvalid_o,
  output logic         s_axis_txc_tlast_o,
  input  logic         s_axis_txc_tready_i,

  // open_eth_mac_1g_switch's s_axis_txd, axis_clk domain
  output logic [31:0] s_axis_txd_tdata_o,
  output logic [3:0]  s_axis_txd_tkeep_o,
  output logic         s_axis_txd_tlast_o,
  output logic         s_axis_txd_tvalid_o,
  input  logic         s_axis_txd_tready_i
);

  assign s_axis_txc_tlast_o = 1'b1; // always a single-beat control transfer

  localparam int ENTRY_W = 16 + 1 + 1; // data16, upper byte valid, eop

  // ---- clk side: one word per cycle straight into the FIFO ----
  logic fifo_full;
  assign s_axis_tready_o = !fifo_full;
  wire   fifo_wr_en      = s_axis_tvalid_i && !fifo_full;
  wire [ENTRY_W-1:0] fifo_wr_data = {s_axis_tlast_i, s_axis_tkeep_i[1], s_axis_tdata_i};

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_rd_en, fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (clk),
    .wr_rst_n  (rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (axis_clk),
    .rd_rst_n  (axis_rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- axis_clk side: one txc beat per frame, then words -> 32-bit beats ----
  // async_fifo's read side is a combinational peek-before-pop (first word fall
  // through). State: S_TXC issues the frame's control beat; S_RUN assembles beats
  // from popped words and presents them from an output register; after the
  // frame's last word is popped nothing more is popped until the last beat has
  // been accepted (the next frame needs its own txc beat first).
  typedef enum logic {S_TXC, S_RUN} tx_state_t;
  tx_state_t state_q;

  logic        hold_v_q;                 // first word of a beat is held
  logic [15:0] hold_data_q;
  logic        out_v_q;                  // output beat register
  logic [31:0] out_data_q;
  logic [3:0]  out_keep_q;
  logic        out_last_q;
  logic        frame_done_q;             // final word already popped

  wire [15:0] w_data = fifo_rd_data[15:0];
  wire        w_k1   = fifo_rd_data[16];
  wire        w_eop  = fifo_rd_data[17];

  // the output register can take a new beat if it is empty or being taken now
  wire out_free = !out_v_q || s_axis_txd_tready_i;

  wire can_pop_w0  = (state_q == S_RUN) && !fifo_empty && !frame_done_q && !hold_v_q && (!w_eop || out_free);
  wire can_pop_w1  = (state_q == S_RUN) && !fifo_empty && !frame_done_q &&  hold_v_q && out_free;
  assign fifo_rd_en = can_pop_w0 || can_pop_w1;

  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
      state_q      <= S_TXC;
      hold_v_q     <= 1'b0;
      out_v_q      <= 1'b0;
      frame_done_q <= 1'b0;
    end else begin
      if (out_v_q && s_axis_txd_tready_i) out_v_q <= 1'b0;

      unique case (state_q)
        S_TXC: begin
          if (s_axis_txc_tvalid_o && s_axis_txc_tready_i) begin
            state_q      <= S_RUN;
            frame_done_q <= 1'b0;
            hold_v_q     <= 1'b0;
          end
        end
        S_RUN: begin
          if (can_pop_w0) begin
            if (w_eop) begin
              // lone final word: partial beat
              out_v_q      <= 1'b1;
              out_data_q   <= {16'h0000, w_data};
              out_keep_q   <= {2'b00, w_k1, 1'b1};
              out_last_q   <= 1'b1;
              frame_done_q <= 1'b1;
            end else begin
              hold_v_q    <= 1'b1;
              hold_data_q <= w_data;
            end
          end
          if (can_pop_w1) begin
            out_v_q      <= 1'b1;
            out_data_q   <= {w_data, hold_data_q};
            out_keep_q   <= {w_k1, 3'b111};
            out_last_q   <= w_eop;
            hold_v_q     <= 1'b0;
            if (w_eop) frame_done_q <= 1'b1;
          end
          // last beat accepted by the MAC -> next frame
          if (frame_done_q && out_v_q && s_axis_txd_tready_i && out_last_q) state_q <= S_TXC;
        end
        default: state_q <= S_TXC;
      endcase
    end
  end

  always_comb begin
    s_axis_txc_tvalid_o = (state_q == S_TXC) && !fifo_empty;

    s_axis_txd_tdata_o  = out_data_q;
    s_axis_txd_tkeep_o  = out_keep_q;
    s_axis_txd_tlast_o  = out_last_q;
    s_axis_txd_tvalid_o = out_v_q;
  end

endmodule
