// cpu_dma_wr.sv
//
// The CPU port's own dedicated AXI4 write master, serving cpu_port_top.sv's
// ingress_port_wr (PORT_ID=5) instance. Uses the same two-word read pipeline
// as ingress_dma_wr, without arbitration or per-port muxes. Once filled,
// the pipeline transfers one 128-bit beat per clock when WREADY is asserted.
// A slot is reserved for every synchronous RAM read in flight, preserving
// data under arbitrary AXI backpressure. One burst/frame is outstanding;
// completion remains after BRESP. Buffers are aligned and at most 2048 bytes.

module cpu_dma_wr
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // frame handshake with ingress_port_wr#(.PORT_ID(5))
  input  logic                  frame_ready_i,
  input  logic [BUF_ID_W-1:0]   frame_bufid_i,
  input  logic [LENGTH_W-1:0]   frame_length_i,
  output logic                  frame_gnt_o,
  output logic                  frame_rd_en_o,
  output logic [BEAT_IDX_W-1:0] frame_rd_addr_o,
  input  logic [AXI_DATA_W-1:0] frame_rd_data_i,
  output logic                  frame_dma_done_o,

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

  // ---- per-transfer registers, latched once at grant time ----
  logic [AXI_ADDR_W-1:0] awaddr_q;
  logic [BEAT_IDX_W:0]   num_beats_q;  // extra bit: up to BEATS_PER_BUFFER inclusive
  logic [3:0]            last_bytes_q; // 1..16 valid bytes in the final beat
  logic [BEAT_IDX_W:0]   beat_idx_q;   // current beat being transferred

  wire last_beat = (beat_idx_q + 1'b1 == num_beats_q);

  typedef enum logic [2:0] {S_IDLE, S_GRANT, S_AW, S_W, S_BRESP, S_DONE} state_t;
  state_t state_q, state_d;

  // Two queued words plus explicit accounting for the synchronous RAM read
  // in flight. Reserve a slot before issuing each read: its response cannot
  // be backpressured. With WREADY high, push/pop/read overlap every cycle.
  logic [AXI_DATA_W-1:0] data0_q, data1_q;
  logic read_ptr_q, write_ptr_q, read_pending_q;
  logic [1:0] queued_q;
  logic [BEAT_IDX_W:0] issued_q;
  wire write_fire = (state_q == S_W) && (queued_q != 0) && m_axi_wready;
  wire [2:0] reserved = {1'b0,queued_q} + {2'b0,read_pending_q};
  wire issue_read = (state_q == S_W) && (issued_q < num_beats_q) &&
                    ((reserved < 3'd2) || write_fire);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_ptr_q <= 0; write_ptr_q <= 0; queued_q <= 0;
      read_pending_q <= 0; issued_q <= 0;
    end else begin
      read_pending_q <= issue_read;
      if (state_q == S_IDLE) begin
        read_ptr_q <= 0; write_ptr_q <= 0; queued_q <= 0;
        read_pending_q <= 0; issued_q <= 0;
      end else begin
        if (issue_read) issued_q <= issued_q + 1'b1;
        if (read_pending_q) begin
          if (write_ptr_q) data1_q <= frame_rd_data_i;
          else             data0_q <= frame_rd_data_i;
          write_ptr_q <= !write_ptr_q;
        end
        if (write_fire) read_ptr_q <= !read_ptr_q;
        case ({read_pending_q,write_fire})
          2'b10: queued_q <= queued_q + 1'b1;
          2'b01: queued_q <= queued_q - 1'b1;
          default: ;
        endcase
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
    end else begin
      state_q <= state_d;

      if (state_q == S_IDLE && frame_ready_i) begin
        awaddr_q <= DDR_BASE_ADDR + (AXI_ADDR_W'(frame_bufid_i) * AXI_ADDR_W'(BUFFER_BYTES));
        // num_beats = ceil(length/16); last_bytes = bytes valid in the final beat
        num_beats_q  <= (BEAT_IDX_W+1)'((32'(frame_length_i) + 32'd15) >> 4);
        last_bytes_q <= 4'((32'(frame_length_i) - 32'd1) & 15) + 4'd1; // 1..16, not 0..15
        beat_idx_q   <= '0;
      end

      if (state_q == S_W && m_axi_wvalid && m_axi_wready && !last_beat) begin
        beat_idx_q <= beat_idx_q + 1'b1;
      end
    end
  end

  // Boundary-crossing outputs (read by ingress_port_wr's own if/case-based
  // always_comb) computed as plain continuous logic from registered state
  // for grant/done, and pipeline occupancy for read enable. Keep these
  // outside the state/output block to avoid combinational scheduling loops.
  wire grant_win    = (state_q == S_GRANT);
  wire done_win     = (state_q == S_DONE);

  assign frame_gnt_o      = grant_win;
  assign frame_rd_en_o    = issue_read;
  assign frame_dma_done_o = done_win;

  always_comb begin
    state_d = state_q;

    frame_rd_addr_o  = issued_q[BEAT_IDX_W-1:0];

    m_axi_awid    = AXI_ID_W'(0);
    m_axi_awaddr  = awaddr_q;
    m_axi_awlen   = 8'(num_beats_q - 1'b1);
    m_axi_awsize  = 3'd4; // 16 bytes/beat = 2^4
    m_axi_awburst = 2'b01; // INCR
    m_axi_awvalid = 1'b0;

    m_axi_wdata  = read_ptr_q ? data1_q : data0_q;
    m_axi_wstrb  = last_beat ? ((last_bytes_q == 4'd0) ? {AXI_STRB_W{1'b1}} : (AXI_STRB_W'(1) << last_bytes_q) - AXI_STRB_W'(1))
                              : {AXI_STRB_W{1'b1}};
    m_axi_wlast  = last_beat;
    m_axi_wvalid = 1'b0;

    m_axi_bready = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (frame_ready_i) state_d = S_GRANT;
      end
      S_GRANT: begin
        state_d = S_AW;
      end
      S_AW: begin
        m_axi_awvalid = 1'b1;
        if (m_axi_awready) state_d = S_W;
      end
      S_W: begin
        m_axi_wvalid = (queued_q != 0);
        if (write_fire && last_beat) state_d = S_BRESP;
      end
      S_BRESP: begin
        m_axi_bready = 1'b1;
        if (m_axi_bvalid) state_d = S_DONE; // BRESP not checked: no error-recovery path in this first pass
      end
      S_DONE: begin
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
