// switch_egress_to_mac_txd.sv
//
// This switch's egress AXI4-Stream convention (16-bit, clk domain,
// 62.5MHz) -> open_eth_mac_1g_switch's s_axis_txd (32-bit AXI4-Stream,
// its own axis_clk domain -- 150MHz per that core's README, fixed by its
// internal packet buffer, not reclockable). Two clock domains, mirroring
// rtl/ps_eth/axis_to_gem_tx_r.sv's structure: a clk-side unpacker splits
// each accepted 16-bit/tkeep word into 1-2 bytes, pushed into
// rtl/common/async_fifo.sv; an axis_clk-side gearbox pops bytes back out
// and assembles them into 32-bit/tkeep beats (flushing early, with a
// partial tkeep, on the byte carrying eop).
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
  parameter int FIFO_DEPTH = 128
) (
  input  logic clk,      // fabric clock (62.5 MHz)
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

  localparam int ENTRY_W = 8 + 1; // data + eop

  // ---- clk side: unpack each accepted 16-bit word into 1 or 2 FIFO
  // pushes. Structurally identical to axis_to_gem_tx_r.sv's unpacker --
  // see that file for the detailed reasoning. ----
  typedef enum logic {U_IDLE, U_SECOND} un_state_t;
  un_state_t un_state_q;
  logic [7:0] pending_byte_q;
  logic       pending_eop_q;

  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en, fifo_full;

  always_comb begin
    fifo_wr_en      = 1'b0;
    fifo_wr_data    = '0;
    s_axis_tready_o = 1'b0;

    unique case (un_state_q)
      U_IDLE: begin
        s_axis_tready_o = !fifo_full;
        if (s_axis_tvalid_i && !fifo_full) begin
          fifo_wr_en   = 1'b1;
          fifo_wr_data = {s_axis_tkeep_i[1] ? 1'b0 : s_axis_tlast_i, s_axis_tdata_i[7:0]};
        end
      end
      U_SECOND: begin
        if (!fifo_full) begin
          fifo_wr_en   = 1'b1;
          fifo_wr_data = {pending_eop_q, pending_byte_q};
        end
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      un_state_q <= U_IDLE;
    end else begin
      unique case (un_state_q)
        U_IDLE: begin
          if (s_axis_tvalid_i && !fifo_full && s_axis_tkeep_i[1]) begin
            pending_byte_q <= s_axis_tdata_i[15:8];
            pending_eop_q  <= s_axis_tlast_i;
            un_state_q     <= U_SECOND;
          end
        end
        U_SECOND: begin
          if (!fifo_full) un_state_q <= U_IDLE;
        end
        default: un_state_q <= U_IDLE;
      endcase
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
    .rd_clk    (axis_clk),
    .rd_rst_n  (axis_rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- axis_clk side: issue one txc beat per frame, then gearbox
  // popped bytes into 32-bit txd beats (flushing early, partial tkeep,
  // on the byte carrying eop). async_fifo's read side is a
  // combinational peek-before-pop, no extra registered-read wait state
  // needed (see the same note in the ingress-direction module). ----
  wire       byte_eop = fifo_rd_data[8];
  wire [7:0] byte_val = fifo_rd_data[7:0];

  typedef enum logic [1:0] {S_TXC, S_ACC, S_PRESENT} tx_state_t;
  tx_state_t state_q;

  logic [31:0] acc_q;
  logic [1:0]  word_idx_q;   // 0..3, next lane to fill

  logic [31:0] beat_data_q;
  logic [3:0]  beat_keep_q;
  logic        beat_last_q;

  // combinational "merge this popped byte into the accumulator", case on
  // a constant lane index -- same rationale as every other byte-
  // accumulator in this project (see ingress_port_wr.sv).
  logic [31:0] acc_next;
  always_comb begin
    acc_next = acc_q;
    unique case (word_idx_q)
      2'd0:    acc_next[7:0]   = byte_val;
      2'd1:    acc_next[15:8]  = byte_val;
      2'd2:    acc_next[23:16] = byte_val;
      default: acc_next[31:24] = byte_val;
    endcase
  end

  wire word_full   = (word_idx_q == 2'd3);
  wire pop_now     = (state_q == S_ACC) && !fifo_empty;
  wire commit_beat = pop_now && (word_full || byte_eop);

  // tkeep for the beat being committed: all lanes up to and including
  // word_idx_q are valid. A case on a constant index, not a function --
  // this module is instantiated once per PL GMII port, and a package/
  // module-local `function automatic` called every cycle from more than
  // one instance of the calling module is a confirmed Icarus Verilog
  // 12.0 corruption bug (see rtl/dma/axi_dma_pkg.sv's header note for
  // the same rationale applied elsewhere in this project).
  logic [3:0] keep_for_this_count;
  always_comb begin
    unique case (word_idx_q)
      2'd0:    keep_for_this_count = 4'b0001;
      2'd1:    keep_for_this_count = 4'b0011;
      2'd2:    keep_for_this_count = 4'b0111;
      default: keep_for_this_count = 4'b1111;
    endcase
  end

  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
      state_q    <= S_TXC;
      word_idx_q <= '0;
    end else begin
      unique case (state_q)
        S_TXC: begin
          if (s_axis_txc_tvalid_o && s_axis_txc_tready_i) begin
            state_q    <= S_ACC;
            word_idx_q <= '0;
          end
        end
        S_ACC: begin
          if (pop_now) begin
            acc_q <= acc_next;
            if (commit_beat) begin
              beat_data_q <= acc_next;
              beat_keep_q <= keep_for_this_count;
              beat_last_q <= byte_eop;
              state_q     <= S_PRESENT;
            end else begin
              word_idx_q <= word_idx_q + 1'b1;
            end
          end
        end
        S_PRESENT: begin
          if (s_axis_txd_tready_i) begin
            word_idx_q <= '0;
            // Icarus Verilog 13.0 requires an explicit cast on an
            // enum-typed ternary assigned to an enum-typed variable
            // (12.0 accepted this without one).
            state_q    <= tx_state_t'(beat_last_q ? S_TXC : S_ACC);
          end
        end
        default: state_q <= S_TXC;
      endcase
    end
  end

  always_comb begin
    fifo_rd_en = pop_now;

    s_axis_txc_tvalid_o = (state_q == S_TXC) && !fifo_empty;

    s_axis_txd_tdata_o  = beat_data_q;
    s_axis_txd_tkeep_o  = beat_keep_q;
    s_axis_txd_tlast_o  = beat_last_q;
    s_axis_txd_tvalid_o = (state_q == S_PRESENT);
  end

endmodule
