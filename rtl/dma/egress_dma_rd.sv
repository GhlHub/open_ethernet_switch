// egress_dma_rd.sv
//
// The single shared AXI4 read master serving all NUM_PHYS_PORTS egress
// ports. Mirrors ingress_dma_wr.sv: arbitrates among the ports' "frame_req"
// requests (round-robin); once a winner is picked, that port is latched
// as the active port for the whole multi-beat transfer (no re-arbitration
// mid-burst) -- issues a single AXI4 INCR burst sized exactly to the
// frame's actual length and writes each returned beat into that port's
// local frame_ram.
//
// Single-outstanding, same rationale as ingress_dma_wr.sv (one burst per
// frame always suffices given BUFFER_BYTES=2048 naturally-aligned
// buffers; pipelining multiple outstanding reads is a later throughput
// enhancement, not expected to be needed at these port counts/line rates).
//
// Simpler than the write engine: there's no per-beat byte-enable masking
// to compute (a read simply returns whatever's in DDR; the consuming
// egress_port_rd.sv already knows the frame's true length and only ever
// serializes that many bytes back out, ignoring any padding in the final
// beat) and no response-phase wait (AXI4 read has no analogue to BRESP --
// RLAST on the last beat is the only completion signal needed).

module egress_dma_rd
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // per-port frame handshake (arrays, index = physical port 0..NUM_PHYS_PORTS-1)
  input  logic [NUM_PHYS_PORTS-1:0]                  frame_req_i,
  input  logic [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0]    frame_bufid_i,
  input  logic [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0]    frame_length_i,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_gnt_o,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_wr_en_o,
  output logic [BEAT_IDX_W-1:0]                      frame_wr_addr_o,
  output logic [AXI_DATA_W-1:0]                      frame_wr_data_o,
  output logic [NUM_PHYS_PORTS-1:0]                  frame_dma_done_o,

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

  // ---- arbiter (padded to DMA_ARB_N; upper request bits tied 0) ----
  logic [DMA_ARB_N-1:0] grant_p;
  logic                 arb_valid;

  rr_arbiter #(.N(DMA_ARB_N)) u_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(DMA_ARB_N-NUM_PHYS_PORTS){1'b0}}, frame_req_i}),
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

  logic [PP_W-1:0]       active_port_q;
  logic [AXI_ADDR_W-1:0] araddr_q;
  logic [BEAT_IDX_W:0]   num_beats_q; // extra bit: up to BEATS_PER_BUFFER inclusive
  logic [BEAT_IDX_W:0]   beat_idx_q;  // current beat being transferred

  wire last_beat = (beat_idx_q + 1'b1 == num_beats_q);

  // combinational one-hot-grant -> binary index, registered below with a
  // plain (loop-free) assignment -- same rationale/precaution as
  // ingress_dma_wr.sv's grant_idx_comb.
  logic [PP_W-1:0] grant_idx_comb;
  always_comb begin
    grant_idx_comb = '0;
    for (int p = 0; p < NUM_PHYS_PORTS; p++) begin
      if (grant[p]) grant_idx_comb = PP_W'(p);
    end
  end

  typedef enum logic [2:0] {S_IDLE, S_GRANT, S_AR, S_R, S_DONE} state_t;
  state_t state_q, state_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
    end else begin
      state_q <= state_d;

      if (state_q == S_IDLE && arb_valid) begin
        active_port_q <= grant_idx_comb;
        araddr_q <= DDR_BASE_ADDR + (AXI_ADDR_W'(grant_bufid_muxed) * AXI_ADDR_W'(BUFFER_BYTES));
        num_beats_q <= (BEAT_IDX_W+1)'((32'(grant_length_muxed) + 32'd15) >> 4); // ceil(length/16)
        beat_idx_q  <= '0;
      end

      if (state_q == S_R && m_axi_rvalid && m_axi_rready && !last_beat) begin
        beat_idx_q <= beat_idx_q + 1'b1;
      end
    end
  end

  always_comb begin
    state_d = state_q;

    frame_gnt_o      = '0;
    frame_wr_en_o    = '0;
    frame_wr_addr_o  = beat_idx_q[BEAT_IDX_W-1:0];
    frame_wr_data_o  = m_axi_rdata;
    frame_dma_done_o = '0;

    m_axi_arid    = AXI_ID_W'(0);
    m_axi_araddr  = araddr_q;
    m_axi_arlen   = 8'(num_beats_q - 1'b1);
    m_axi_arsize  = 3'd4; // 16 bytes/beat = 2^4
    m_axi_arburst = 2'b01; // INCR
    m_axi_arvalid = 1'b0;

    m_axi_rready = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (arb_valid) state_d = S_GRANT;
      end
      S_GRANT: begin
        // whole-vector shift rather than a variable(register)-indexed
        // bit-select write -- see the note in rtl/buf_mgr/queue_mgr.sv:
        // Icarus Verilog 12.0 has a confirmed bug with the latter.
        frame_gnt_o = NUM_PHYS_PORTS'(1) << active_port_q;
        state_d = S_AR;
      end
      S_AR: begin
        m_axi_arvalid = 1'b1;
        if (m_axi_arready) state_d = S_R;
      end
      S_R: begin
        m_axi_rready = 1'b1;
        if (m_axi_rvalid) begin
          frame_wr_en_o   = NUM_PHYS_PORTS'(1) << active_port_q;
          frame_wr_addr_o = beat_idx_q[BEAT_IDX_W-1:0];
          if (m_axi_rlast) state_d = S_DONE; // RRESP not checked: no error-recovery path in this first pass
        end
      end
      S_DONE: begin
        frame_dma_done_o = NUM_PHYS_PORTS'(1) << active_port_q;
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
