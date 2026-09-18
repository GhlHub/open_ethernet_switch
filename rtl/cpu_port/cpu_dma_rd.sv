// cpu_dma_rd.sv
//
// The CPU port's own dedicated AXI4 read master, serving cpu_port_top.sv's
// egress_port_rd (PORT_ID=5) instance. Mirrors rtl/dma/egress_dma_rd.sv
// exactly (same state machine, same single-outstanding-transaction
// rationale -- see that file's header) but with the round-robin arbiter
// and per-port muxing stripped out, for the same reason as cpu_dma_wr.sv:
// this engine serves exactly one requester, and stays dedicated rather
// than folding into the 5-physical-port shared egress_dma_rd instance so
// that already-verified engine never has to change shape.

module cpu_dma_rd
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // frame handshake with egress_port_rd#(.PORT_ID(5))
  input  logic                  frame_req_i,
  input  logic [BUF_ID_W-1:0]   frame_bufid_i,
  input  logic [LENGTH_W-1:0]   frame_length_i,
  output logic                  frame_gnt_o,
  output logic                  frame_wr_en_o,
  output logic [BEAT_IDX_W-1:0] frame_wr_addr_o,
  output logic [AXI_DATA_W-1:0] frame_wr_data_o,
  output logic                  frame_dma_done_o,

  // AXI4 read master
  output logic [AXI_ID_W-1:0]   m_axi_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,

  input  logic [AXI_ID_W-1:0]   m_axi_rid,
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  // ---- per-transfer registers, latched once at grant time ----
  logic [AXI_ADDR_W-1:0] araddr_q;
  logic [BEAT_IDX_W:0]   num_beats_q; // extra bit: up to BEATS_PER_BUFFER inclusive
  logic [BEAT_IDX_W:0]   beat_idx_q;  // current beat being transferred

  wire last_beat = (beat_idx_q + 1'b1 == num_beats_q);

  typedef enum logic [2:0] {S_IDLE, S_GRANT, S_AR, S_R, S_DONE} state_t;
  state_t state_q, state_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
    end else begin
      state_q <= state_d;

      if (state_q == S_IDLE && frame_req_i) begin
        araddr_q <= DDR_BASE_ADDR + (AXI_ADDR_W'(frame_bufid_i) * AXI_ADDR_W'(BUFFER_BYTES));
        num_beats_q <= (BEAT_IDX_W+1)'((32'(frame_length_i) + 32'd15) >> 4); // ceil(length/16)
        beat_idx_q  <= '0;
      end

      if (state_q == S_R && m_axi_rvalid && m_axi_rready && !last_beat) begin
        beat_idx_q <= beat_idx_q + 1'b1;
      end
    end
  end

  // Boundary-crossing outputs (read by egress_port_rd's own if/case-based
  // always_comb) computed as plain continuous logic from registered state
  // alone -- same fix, same rationale, as rtl/dma/ingress_port_wr.sv's
  // header note on this exact pattern.
  wire grant_win = (state_q == S_GRANT);
  wire done_win  = (state_q == S_DONE);

  assign frame_gnt_o      = grant_win;
  assign frame_dma_done_o = done_win;

  always_comb begin
    state_d = state_q;

    frame_wr_en_o    = 1'b0;
    frame_wr_addr_o  = beat_idx_q[BEAT_IDX_W-1:0];
    frame_wr_data_o  = m_axi_rdata;

    m_axi_arid    = AXI_ID_W'(0);
    m_axi_araddr  = araddr_q;
    m_axi_arlen   = 8'(num_beats_q - 1'b1);
    m_axi_arsize  = 3'd4; // 16 bytes/beat = 2^4
    m_axi_arburst = 2'b01; // INCR
    m_axi_arvalid = 1'b0;

    m_axi_rready = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (frame_req_i) state_d = S_GRANT;
      end
      S_GRANT: begin
        state_d = S_AR;
      end
      S_AR: begin
        m_axi_arvalid = 1'b1;
        if (m_axi_arready) state_d = S_R;
      end
      S_R: begin
        m_axi_rready = 1'b1;
        if (m_axi_rvalid) begin
          frame_wr_en_o   = 1'b1;
          frame_wr_addr_o = beat_idx_q[BEAT_IDX_W-1:0];
          if (m_axi_rlast) state_d = S_DONE; // RRESP not checked: no error-recovery path in this first pass
        end
      end
      S_DONE: begin
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
