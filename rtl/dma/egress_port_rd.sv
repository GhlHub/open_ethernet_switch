// egress_port_rd.sv
//
// One instance per physical egress port. Mirrors ingress_port_wr.sv:
// pulls a {bufid, length} off buf_mgr_core's dequeue interface for this
// port, hands off to the shared egress_dma_rd engine to DMA-read the
// frame from DDR into a local 128-bit-wide frame buffer, releases the
// DDR buffer as soon as that local copy is complete (the shared buffer
// pool entry isn't needed past that point), then drains the local copy
// out one 16-bit word at a time (62.5 MHz core clock domain -- widened
// from an earlier 8-bit/125 MHz convention specifically to ease timing
// closure on the fabric) to the MAC (or a ps_gem_axis_bridge's s_axis_*
// slave, for a PS GEM port).
//
// tkeep[1:0] marks per-byte validity (bit0 = lower byte, bit1 = upper
// byte); only the final word of an odd-length frame ever has tkeep=01,
// everything else is 2'b11. Anything downstream that's itself byte-wide
// (GMII, the PS GEM FIFO interface) unpacks this back into individual
// bytes -- see rtl/ps_eth/ for that adapter.
//
// Store-and-forward, single frame in flight per port -- same rationale
// and same future double-buffering enhancement note as ingress_port_wr.sv.
//
// Only ever streams frames that were already validated/buffered by the
// ingress side, so there's no tuser/error concept here -- m_axis_tuser
// doesn't exist on this port's AXI4-Stream.

module egress_port_rd
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream TX out (16-bit)
  output logic [15:0] m_axis_tdata,
  output logic [1:0]  m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  input  logic         m_axis_tready,

  // buf_mgr_core dequeue (this port's slot)
  output logic                dequeue_req_o,
  input  logic                dequeue_valid_i,
  input  logic [BUF_ID_W-1:0] dequeue_bufid_i,
  input  logic [LENGTH_W-1:0] dequeue_length_i,

  // buf_mgr_core release (this port's slot)
  output logic                release_req_o,
  output logic [BUF_ID_W-1:0] release_bufid_o,
  input  logic                release_gnt_i,

  // shared egress_dma_rd engine handshake
  output logic                  frame_req_o,     // level: this port wants a DMA read
  output logic [BUF_ID_W-1:0]   frame_bufid_o,
  output logic [LENGTH_W-1:0]   frame_length_o,
  input  logic                  frame_gnt_i,     // shared engine has selected this port
  input  logic                  frame_wr_en_i,   // shared engine writing a beat this cycle
  input  logic [BEAT_IDX_W-1:0] frame_wr_addr_i,
  input  logic [AXI_DATA_W-1:0] frame_wr_data_i,
  input  logic                  frame_dma_done_i
);

  // ---- local frame buffer: single port (written during DMA drain,
  // read during transmit -- temporally disjoint, single-frame-in-flight) ----
  logic [AXI_DATA_W-1:0] frame_ram [0:BEATS_PER_BUFFER-1];
  logic                  fram_en, fram_we;
  logic [BEAT_IDX_W-1:0] fram_addr;
  logic [AXI_DATA_W-1:0] fram_wdata;
  logic [AXI_DATA_W-1:0] fram_rdata_q;

  always_ff @(posedge clk) begin
    if (fram_en) begin
      if (fram_we) frame_ram[fram_addr] <= fram_wdata;
      fram_rdata_q <= frame_ram[fram_addr];
    end
  end

  logic [BUF_ID_W-1:0]   bufid_q;
  logic [LENGTH_W-1:0]   length_q;
  logic [BEAT_IDX_W:0]   num_beats_q;  // extra bit: up to BEATS_PER_BUFFER inclusive
  logic [3:0]            last_bytes_q; // 1..16 valid bytes in the final beat (0 means 16)

  logic [BEAT_IDX_W:0]   beat_idx_q;   // beat currently loaded/being drained
  logic [2:0]            word_pos_q;   // 0..7, next lane to send
  logic [AXI_DATA_W-1:0] cur_beat_q;   // latched copy of fram_rdata_q for this beat

  // index (0-7) of the last valid word in the final beat, and whether
  // that word is partial (only its lower byte real) -- both derived from
  // last_bytes_q's same 0-means-16 wraparound convention already used
  // for the byte-level version of this in ingress_dma_wr.sv/
  // egress_dma_rd.sv, so no separate case split is needed for the
  // last_bytes_q==0 (full 16-byte final beat) case.
  wire [2:0] last_word_idx     = 3'((last_bytes_q - 4'd1) >> 1);
  wire       last_word_partial = last_bytes_q[0];

  wire last_beat           = (beat_idx_q + 1'b1 == num_beats_q);
  wire last_lane_this_beat = last_beat ? (word_pos_q == last_word_idx) : (word_pos_q == 3'd7);

  typedef enum logic [2:0] {S_DEQ_WAIT, S_DMA_REQ, S_DMA_SERVE, S_RELEASE_WAIT, S_RD_ISSUE, S_RD_WAIT, S_STREAM} state_t;
  state_t state_q, state_d;

  wire word_sent = (state_q == S_STREAM) && m_axis_tvalid && m_axis_tready;

  // current word, read via a case on a constant lane index (0-7) rather
  // than a variable/register-indexed part-select -- see the note in
  // ingress_port_wr.sv (same rationale, this is the read-side mirror of
  // that module's word-accumulator write case).
  logic [15:0] cur_word;
  always_comb begin
    unique case (word_pos_q)
      3'd0:    cur_word = cur_beat_q[15:0];
      3'd1:    cur_word = cur_beat_q[31:16];
      3'd2:    cur_word = cur_beat_q[47:32];
      3'd3:    cur_word = cur_beat_q[63:48];
      3'd4:    cur_word = cur_beat_q[79:64];
      3'd5:    cur_word = cur_beat_q[95:80];
      3'd6:    cur_word = cur_beat_q[111:96];
      default: cur_word = cur_beat_q[127:112];
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= S_DEQ_WAIT;
      beat_idx_q  <= '0;
      word_pos_q  <= '0;
    end else begin
      state_q <= state_d;

      if (state_q == S_DEQ_WAIT && dequeue_valid_i) begin
        bufid_q      <= dequeue_bufid_i;
        length_q     <= dequeue_length_i;
        num_beats_q  <= (BEAT_IDX_W+1)'((32'(dequeue_length_i) + 32'd15) >> 4);
        last_bytes_q <= 4'((32'(dequeue_length_i) - 32'd1) & 15) + 4'd1; // 1..16, not 0..15
      end

      if (state_q == S_RELEASE_WAIT && release_gnt_i) begin
        beat_idx_q <= '0;
        word_pos_q <= '0;
      end

      if (state_q == S_RD_WAIT) begin
        cur_beat_q <= fram_rdata_q;
      end

      if (word_sent) begin
        if (last_lane_this_beat) begin
          word_pos_q <= '0;
          beat_idx_q <= beat_idx_q + 1'b1;
        end else begin
          word_pos_q <= word_pos_q + 1'b1;
        end
      end
    end
  end

  // Boundary-crossing outputs (each read by another module's own if/case-
  // based always_comb: dequeue_req_o by queue_mgr, release_req_o by
  // free_list_mgr, frame_req_o by the shared/dedicated DMA read engine)
  // computed as plain continuous logic from registered state alone --
  // same fix, same rationale, as rtl/dma/ingress_port_wr.sv's header note
  // on this exact pattern (this is egress_port_rd's mirror of that fix).
  wire deq_wait_win     = (state_q == S_DEQ_WAIT);
  wire release_wait_win = (state_q == S_RELEASE_WAIT);
  wire dma_req_win      = (state_q == S_DMA_REQ);

  assign dequeue_req_o   = deq_wait_win;
  assign release_req_o   = release_wait_win;
  assign release_bufid_o = bufid_q;
  assign frame_req_o     = dma_req_win;
  assign frame_bufid_o   = bufid_q;
  assign frame_length_o  = length_q;

  always_comb begin
    state_d = state_q;

    fram_en    = 1'b0;
    fram_we    = 1'b0;
    fram_addr  = '0;
    fram_wdata = frame_wr_data_i;

    m_axis_tdata  = cur_word;
    m_axis_tkeep  = (last_beat && last_lane_this_beat && last_word_partial) ? 2'b01 : 2'b11;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;

    unique case (state_q)
      S_DEQ_WAIT: begin
        if (dequeue_valid_i) state_d = S_DMA_REQ;
      end
      S_DMA_REQ: begin
        if (frame_gnt_i) state_d = S_DMA_SERVE;
      end
      S_DMA_SERVE: begin
        if (frame_wr_en_i) begin
          fram_en   = 1'b1;
          fram_we   = 1'b1;
          fram_addr = frame_wr_addr_i;
        end
        if (frame_dma_done_i) state_d = S_RELEASE_WAIT;
      end
      S_RELEASE_WAIT: begin
        if (release_gnt_i) state_d = S_RD_ISSUE;
      end
      S_RD_ISSUE: begin
        fram_en   = 1'b1;
        fram_we   = 1'b0;
        fram_addr = beat_idx_q[BEAT_IDX_W-1:0];
        state_d   = S_RD_WAIT;
      end
      S_RD_WAIT: begin
        state_d = S_STREAM;
      end
      S_STREAM: begin
        m_axis_tvalid = 1'b1;
        m_axis_tlast  = last_beat && last_lane_this_beat;
        if (word_sent) begin
          if (m_axis_tlast) begin
            state_d = S_DEQ_WAIT;
          end else if (last_lane_this_beat) begin
            state_d = S_RD_ISSUE;
          end
        end
      end
      default: state_d = S_DEQ_WAIT;
    endcase
  end

endmodule
