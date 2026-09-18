// ingress_dma_wr.sv
//
// The single shared AXI4 write master serving all NUM_PHYS_PORTS ingress
// ports. Arbitrates among the ports' "frame_ready" requests (round-robin);
// once a winner is picked, that port is latched as the active port for
// the whole multi-beat transfer (no re-arbitration mid-burst) -- reads
// that port's local frame_ram one beat at a time and streams it out as a
// single AXI4 INCR burst sized exactly to the frame's actual length.
//
// Single-outstanding: this engine only has one AXI4 write transaction in
// flight at a time (no pipelining across frames). Given each buffer never
// crosses a 4KB boundary (BUFFER_BYTES=2048, naturally aligned) and stays
// well under the 256-beat AXI4 burst limit (2048/16=128 beats max), one
// burst per frame is always sufficient -- no burst-splitting logic is
// needed. Pipelining multiple outstanding writes is a throughput
// enhancement for later if the shared bus ever proves to be the
// bottleneck; it isn't expected to be at these port counts/line rates.

module ingress_dma_wr
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // per-port frame handshake (arrays, index = physical port 0..NUM_PHYS_PORTS-1)
  input  logic [NUM_PHYS_PORTS-1:0]                  frame_ready_i,
  input  logic [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0]    frame_bufid_i,
  input  logic [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0]    frame_length_i,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_gnt_o,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_rd_en_o,
  output logic [BEAT_IDX_W-1:0]                      frame_rd_addr_o,
  input  logic [NUM_PHYS_PORTS-1:0][AXI_DATA_W-1:0]  frame_rd_data_i,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_dma_done_o,

  // AXI4 write master
  output logic [AXI_ID_W-1:0]   m_axi_awid,
  output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,

  output logic [AXI_DATA_W-1:0] m_axi_wdata,
  output logic [AXI_STRB_W-1:0] m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,

  input  logic [AXI_ID_W-1:0]   m_axi_bid,
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready
);

  // ---- arbiter (padded to ARB_N; upper request bits tied 0) ----
  logic [DMA_ARB_N-1:0] grant_p;
  logic             arb_valid;

  rr_arbiter #(.N(DMA_ARB_N)) u_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(DMA_ARB_N-NUM_PHYS_PORTS){1'b0}}, frame_ready_i}),
    .grant_o (grant_p),
    .valid_o (arb_valid)
  );

  wire [NUM_PHYS_PORTS-1:0] grant = grant_p[NUM_PHYS_PORTS-1:0];

  logic [BUF_ID_W-1:0] grant_bufid_muxed;
  logic [LENGTH_W-1:0] grant_length_muxed;
  always_comb begin
    grant_bufid_muxed  = '0;
    grant_length_muxed = '0;
    for (int p = 0; p < NUM_PHYS_PORTS; p++) begin
      if (grant[p]) begin
        grant_bufid_muxed  = frame_bufid_i[p];
        grant_length_muxed = frame_length_i[p];
      end
    end
  end

  // ---- per-transfer registers, latched once at grant time ----
  localparam int PP_W = (NUM_PHYS_PORTS > 1) ? $clog2(NUM_PHYS_PORTS) : 1;

  logic [PP_W-1:0]        active_port_q;
  logic [AXI_ADDR_W-1:0]  awaddr_q;
  logic [BEAT_IDX_W:0]    num_beats_q;   // extra bit: up to BEATS_PER_BUFFER inclusive
  logic [3:0]             last_bytes_q;  // 1..16 valid bytes in the final beat
  logic [BEAT_IDX_W:0]    beat_idx_q;    // current beat being transferred

  wire last_beat = (beat_idx_q + 1'b1 == num_beats_q);

  logic [AXI_DATA_W-1:0] rd_data_muxed;
  always_comb begin
    rd_data_muxed = '0;
    for (int p = 0; p < NUM_PHYS_PORTS; p++) begin
      if (active_port_q == PP_W'(p)) rd_data_muxed = frame_rd_data_i[p];
    end
  end

  // Combinational one-hot-grant -> binary index, registered below with a
  // plain (loop-free) assignment. Kept as its own always_comb rather than
  // computed with a for-loop directly inside the always_ff that latches
  // it: every register update elsewhere in this codebase that needed a
  // "which one is set" scan followed this same split, out of caution
  // after the confirmed Icarus Verilog 12.0 bugs around loops/variable
  // indices mutating shared state (see rtl/buf_mgr/queue_mgr.sv and
  // rtl/mac_table/aging_sweep_fsm.sv for the specific confirmed cases;
  // this exact whole-scalar-overwrite pattern is verified safe, but
  // splitting it out costs nothing and removes any doubt).
  logic [PP_W-1:0] grant_idx_comb;
  always_comb begin
    grant_idx_comb = '0;
    for (int p = 0; p < NUM_PHYS_PORTS; p++) begin
      if (grant[p]) grant_idx_comb = PP_W'(p);
    end
  end

  typedef enum logic [2:0] {S_IDLE, S_GRANT, S_AW, S_RD_ISSUE, S_RD_WAIT, S_W, S_BRESP, S_DONE} state_t;
  state_t state_q, state_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
    end else begin
      state_q <= state_d;

      if (state_q == S_IDLE && arb_valid) begin
        active_port_q <= grant_idx_comb;
        awaddr_q <= DDR_BASE_ADDR + (AXI_ADDR_W'(grant_bufid_muxed) * AXI_ADDR_W'(BUFFER_BYTES));
        // num_beats = ceil(length/16); last_bytes = bytes valid in the final beat
        num_beats_q  <= (BEAT_IDX_W+1)'((32'(grant_length_muxed) + 32'd15) >> 4);
        last_bytes_q <= 4'((32'(grant_length_muxed) - 32'd1) & 15) + 4'd1; // 1..16, not 0..15
        beat_idx_q   <= '0;
      end

      if (state_q == S_W && m_axi_wvalid && m_axi_wready && !last_beat) begin
        beat_idx_q <= beat_idx_q + 1'b1;
      end
    end
  end

  always_comb begin
    state_d = state_q;

    frame_gnt_o      = '0;
    frame_rd_en_o    = '0;
    frame_rd_addr_o  = beat_idx_q[BEAT_IDX_W-1:0];
    frame_dma_done_o = '0;

    m_axi_awid    = AXI_ID_W'(0);
    m_axi_awaddr  = awaddr_q;
    m_axi_awlen   = 8'(num_beats_q - 1'b1);
    m_axi_awsize  = 3'd4; // 16 bytes/beat = 2^4
    m_axi_awburst = 2'b01; // INCR
    m_axi_awvalid = 1'b0;

    m_axi_wdata  = rd_data_muxed;
    m_axi_wstrb  = last_beat ? ((last_bytes_q == 4'd0) ? {AXI_STRB_W{1'b1}} : (AXI_STRB_W'(1) << last_bytes_q) - AXI_STRB_W'(1))
                              : {AXI_STRB_W{1'b1}};
    m_axi_wlast  = last_beat;
    m_axi_wvalid = 1'b0;

    m_axi_bready = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (arb_valid) state_d = S_GRANT;
      end
      S_GRANT: begin
        // whole-vector shift rather than a variable(register)-indexed
        // bit-select write -- see the note in rtl/buf_mgr/queue_mgr.sv:
        // Icarus Verilog 12.0 has a confirmed bug with the latter.
        frame_gnt_o = NUM_PHYS_PORTS'(1) << active_port_q;
        state_d = S_AW;
      end
      S_AW: begin
        m_axi_awvalid = 1'b1;
        if (m_axi_awready) state_d = S_RD_ISSUE;
      end
      S_RD_ISSUE: begin
        frame_rd_en_o = NUM_PHYS_PORTS'(1) << active_port_q;
        state_d = S_RD_WAIT;
      end
      S_RD_WAIT: begin
        state_d = S_W;
      end
      S_W: begin
        m_axi_wvalid = 1'b1;
        if (m_axi_wready) begin
          if (last_beat) state_d = S_BRESP;
          else             state_d = S_RD_ISSUE;
        end
      end
      S_BRESP: begin
        m_axi_bready = 1'b1;
        if (m_axi_bvalid) state_d = S_DONE; // BRESP not checked: no error-recovery path in this first pass
      end
      S_DONE: begin
        frame_dma_done_o = NUM_PHYS_PORTS'(1) << active_port_q;
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
