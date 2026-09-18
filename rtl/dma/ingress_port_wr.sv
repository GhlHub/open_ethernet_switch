// ingress_port_wr.sv
//
// One instance per physical ingress port. Receives a frame over a 16-bit-
// wide AXI4-Stream from the MAC (62.5 MHz core clock domain -- widened
// from an earlier 8-bit/125 MHz convention specifically to ease timing
// closure on the fabric), packs it into a local 128-bit-wide frame buffer
// (sized for one max-length frame -- BEATS_PER_BUFFER entries), and on a
// good tlast: allocates a buffer from buf_mgr_core, hands the frame off
// to the shared ingress_dma_wr engine for the actual AXI4 write burst to
// DDR, then enqueues it into buf_mgr_core once the DMA completes.
//
// tkeep[1:0] marks per-byte validity within a transfer (bit0 = lower byte,
// bit1 = upper byte); every transfer keeps at least the lower byte valid,
// and only the tlast transfer may have tkeep=2'b01 (odd-length frame, its
// last byte alone in that 16-bit word). Anything feeding s_axis_* that's
// itself byte-wide (GMII, the PS GEM FIFO interface) packs two bytes into
// one word before presenting it here -- see rtl/ps_eth/ for that adapter.
//
// Store-and-forward, single frame in flight per port: the next frame's
// data isn't accepted (s_axis_tready stays low) until the current one has
// fully drained through DMA + enqueue. This is the simple, correct first
// implementation; double-buffering the frame RAM to let a port receive
// its next frame while the previous one is still draining is a natural
// throughput enhancement if a single in-flight frame ever proves to be a
// bottleneck (it usually won't: draining a frame over the shared AXI bus
// is far faster than receiving the next one from the MAC, and Ethernet's
// inter-frame gap provides some natural slack).
//
// dest_mask_i/dest_mask_valid_i model the forwarding decision (e.g. a MAC
// address table lookup) as an external input -- that lookup isn't wired
// up yet; whatever drives it just needs to assert dest_mask_valid_i with
// a stable dest_mask_i sometime before/soon after this port asserts
// enqueue_req_o's precondition (frame fully DMA'd).

module ingress_port_wr
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream RX from the MAC (16-bit; tuser = frame error, drop)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  output logic         s_axis_tready,

  // forwarding decision (placeholder until the MAC table is wired in)
  input  logic [NUM_PORTS-1:0] dest_mask_i,
  input  logic                 dest_mask_valid_i,

  // buf_mgr_core alloc (this port's slot)
  output logic                alloc_req_o,
  input  logic                alloc_gnt_i,
  input  logic [BUF_ID_W-1:0] alloc_bufid_i,

  // buf_mgr_core enqueue (this port's slot)
  output logic                     enqueue_req_o,
  output logic [BUF_ID_W-1:0]      enqueue_bufid_o,
  output logic [LENGTH_W-1:0]      enqueue_length_o,
  output logic [NUM_PORTS-1:0]     enqueue_destmask_o,
  input  logic                     enqueue_gnt_i,

  // shared ingress_dma_wr engine handshake
  output logic                    frame_ready_o,  // level: complete good frame waiting to DMA
  output logic [BUF_ID_W-1:0]     frame_bufid_o,
  output logic [LENGTH_W-1:0]     frame_length_o,
  input  logic                    frame_gnt_i,     // shared engine has selected this port
  input  logic                    frame_rd_en_i,   // shared engine issuing a beat read this cycle
  input  logic [BEAT_IDX_W-1:0]   frame_rd_addr_i,
  output logic [AXI_DATA_W-1:0]   frame_rd_data_o, // valid 1 cycle after frame_rd_en_i/addr
  input  logic                    frame_dma_done_i
);

  // ---- local frame buffer: single port (write during receive, read
  // during DMA drain -- temporally disjoint, single-frame-in-flight) ----
  logic [AXI_DATA_W-1:0] frame_ram [0:BEATS_PER_BUFFER-1];
  logic                   fram_en, fram_we;
  logic [BEAT_IDX_W-1:0]  fram_addr;
  logic [AXI_DATA_W-1:0]  fram_wdata;
  logic [AXI_DATA_W-1:0]  fram_rdata_q;

  always_ff @(posedge clk) begin
    if (fram_en) begin
      if (fram_we) frame_ram[fram_addr] <= fram_wdata;
      fram_rdata_q <= frame_ram[fram_addr];
    end
  end

  assign frame_rd_data_o = fram_rdata_q;

  // ---- word accumulator: packs incoming 16-bit words into a 128-bit
  // beat (8 word-lanes) ----
  logic [AXI_DATA_W-1:0] acc_q;
  logic [2:0]            word_pos_q;   // 0..7, next lane to fill
  logic [BEAT_IDX_W-1:0] wr_beat_q;
  logic [LENGTH_W-1:0]   byte_cnt_q;   // running BYTE count (not word count)
  logic [BUF_ID_W-1:0]   bufid_q;

  typedef enum logic [2:0] {S_RECV, S_ALLOC_WAIT, S_DMA_REQ, S_DMA_SERVE, S_ENQ_WAIT} state_t;
  state_t state_q, state_d;

  wire word_accept = (state_q == S_RECV) && s_axis_tvalid && s_axis_tready;
  wire beat_full    = (word_pos_q == 3'd7);
  wire commit_beat  = word_accept && (beat_full || s_axis_tlast);

  // bytes contributed by this transfer: 2 normally, 1 if tkeep marks the
  // upper byte invalid (only legal on the tlast transfer, odd length)
  wire [1:0] word_bytes = s_axis_tkeep[1] ? 2'd2 : 2'd1;

  // combinational "merge this cycle's word into the accumulator", using a
  // case on a constant lane index (0-7) rather than a variable/register-
  // indexed part-select write -- see the note in rtl/buf_mgr/queue_mgr.sv
  // for why: Icarus Verilog 12.0 has a confirmed bug with the latter.
  logic [AXI_DATA_W-1:0] acc_next;
  always_comb begin
    acc_next = acc_q;
    if (word_accept) begin
      unique case (word_pos_q)
        3'd0:    acc_next[15:0]    = s_axis_tdata;
        3'd1:    acc_next[31:16]   = s_axis_tdata;
        3'd2:    acc_next[47:32]   = s_axis_tdata;
        3'd3:    acc_next[63:48]   = s_axis_tdata;
        3'd4:    acc_next[79:64]   = s_axis_tdata;
        3'd5:    acc_next[95:80]   = s_axis_tdata;
        3'd6:    acc_next[111:96]  = s_axis_tdata;
        default: acc_next[127:112] = s_axis_tdata;
      endcase
    end
  end

  // word_pos_q/wr_beat_q/byte_cnt_q's next values, computed combinationally
  // (mirroring acc_next above) rather than as multiple conditional NBAs to
  // the same register inside the always_ff below: confirmed by direct
  // testing that the previous, more conventional structure (separate
  // `if (s_axis_tlast) reg<=X; else if (beat_full) reg<=Y; else
  // reg<=Z;` branches all targeting the same register in one always_ff)
  // corrupted a >2-beat frame's final commit under Icarus Verilog 12.0
  // and 13.0 alike -- fram_addr (in the separate always_comb below, a
  // plain combinational read of wr_beat_q) and acc_next's own lane-select
  // case (above, reading word_pos_q) would observe the register's *post*-
  // edge value on the exact same transaction that also needed its *pre*-
  // edge value, writing the frame's final partial beat to frame_ram[0]
  // instead of its real index and dropping a word into the wrong
  // accumulator lane. Collapsing each register's update to one
  // unconditional NBA of a combinationally-computed "_next" signal (this
  // exact pattern already used safely for acc_q/acc_next) resolved it;
  // deferring only the reset (to a later clock edge) did not fully.
  // latched frame length: captured the cycle tlast is accepted, held
  // through the rest of this frame's processing. Computed here (as
  // length_next) alongside word_pos_next/wr_beat_next/byte_cnt_next, and
  // NBA'd in the same always_ff below as those registers, rather than in
  // its own separate always_ff reading byte_cnt_q's pre-edge value on the
  // very cycle byte_cnt_q is also reset -- that separate-always_ff
  // structure hit the identical cross-block same-edge hazard documented
  // below, corrupting length_q by exactly one beat_full-frame length
  // once this frame's alloc/enqueue handshakes were live (buf_mgr_core
  // driving real alloc_gnt_i/enqueue_gnt_i, not tied off), even after the
  // fix below for word_pos_q/wr_beat_q/byte_cnt_q themselves.
  logic [LENGTH_W-1:0] length_q;

  logic [2:0]            word_pos_next;
  logic [BEAT_IDX_W-1:0] wr_beat_next;
  logic [LENGTH_W-1:0]   byte_cnt_next;
  logic [LENGTH_W-1:0]   length_next;
  always_comb begin
    word_pos_next = word_pos_q;
    wr_beat_next  = wr_beat_q;
    byte_cnt_next = byte_cnt_q;
    length_next   = length_q;
    if (word_accept) begin
      if (s_axis_tlast) begin
        word_pos_next = '0;
        wr_beat_next  = '0;
        byte_cnt_next = '0;
        length_next   = byte_cnt_q + LENGTH_W'(word_bytes);
      end else if (beat_full) begin
        word_pos_next = '0;
        wr_beat_next  = wr_beat_q + 1'b1;
        byte_cnt_next = byte_cnt_q + LENGTH_W'(word_bytes);
      end else begin
        word_pos_next = word_pos_q + 1'b1;
        byte_cnt_next = byte_cnt_q + LENGTH_W'(word_bytes);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_RECV;
      word_pos_q <= '0;
      wr_beat_q  <= '0;
      byte_cnt_q <= '0;
      length_q   <= '0;
      acc_q      <= '0;
    end else begin
      state_q    <= state_d;
      word_pos_q <= word_pos_next;
      wr_beat_q  <= wr_beat_next;
      byte_cnt_q <= byte_cnt_next;
      length_q   <= length_next;

      if (word_accept) acc_q <= acc_next;

      if (state_q == S_ALLOC_WAIT && alloc_gnt_i) begin
        bufid_q <= alloc_bufid_i;
      end
    end
  end

  // Boundary-crossing outputs (each read by another module's own if/case-
  // based always_comb: alloc_req_o by free_list_mgr, enqueue_req_o by
  // queue_mgr, frame_ready_o by the shared/dedicated DMA write engine) are
  // computed as plain continuous logic here, driven only by registered
  // state, rather than embedded in the sequencer's own case-based
  // always_comb below. Same fix, same rationale, as buf_mgr_pkg's
  // free_list_mgr.sv/queue_mgr.sv header notes: a request signal computed
  // by an if/case-based always_comb, feeding into another module's own
  // if/case-based always_comb whose grant output feeds back here
  // (alloc_gnt_i/enqueue_gnt_i/frame_gnt_i), is a confirmed Icarus Verilog
  // delta-cycle livelock/X-propagation risk when the boundary output
  // shares a sensitivity list with those external signals -- even though
  // its *value* never actually depends on them.
  wire recv_win       = (state_q == S_RECV);
  wire alloc_wait_win = (state_q == S_ALLOC_WAIT);
  wire dma_req_win    = (state_q == S_DMA_REQ);
  wire dma_serve_win  = (state_q == S_DMA_SERVE);
  wire enq_wait_win   = (state_q == S_ENQ_WAIT);

  assign s_axis_tready = recv_win;

  assign alloc_req_o = alloc_wait_win;

  assign frame_ready_o  = dma_req_win;
  assign frame_bufid_o  = bufid_q;
  assign frame_length_o = length_q;

  assign enqueue_req_o      = enq_wait_win && dest_mask_valid_i;
  assign enqueue_bufid_o    = bufid_q;
  assign enqueue_length_o   = length_q;
  assign enqueue_destmask_o = dest_mask_i;

  // frame_ram access (write during S_RECV's commit_beat, read during
  // S_DMA_SERVE's frame_rd_en_i) is likewise pulled into its own narrow
  // always_comb, decoupled from the state-transition block below: it
  // feeds a *separate* always_ff (the frame_ram write/read port, declared
  // earlier in this file) than the one that updates wr_beat_q/word_pos_q
  // themselves, and wr_beat_q is read here (fram_addr) the same cycle
  // it's conditionally reset/incremented -- entangling that read with the
  // state-transition block's much broader sensitivity (alloc_gnt_i,
  // frame_gnt_i, frame_dma_done_i, enqueue_gnt_i, dest_mask_valid_i) is
  // exactly the shape of the Icarus hazard documented above, and was
  // confirmed by testing: a >2-beat frame (the only case where a stale/
  // wrong wr_beat_q is observable) landed its final partial beat at
  // frame_ram[0] instead of frame_ram[2], corrupting an already-committed
  // earlier beat, until this signal was split out.
  always_comb begin
    fram_en    = 1'b0;
    fram_we    = 1'b0;
    fram_addr  = '0;
    fram_wdata = acc_next;

    if (recv_win && commit_beat) begin
      fram_en   = 1'b1;
      fram_we   = 1'b1;
      fram_addr = wr_beat_q;
    end else if (dma_serve_win && frame_rd_en_i) begin
      fram_en   = 1'b1;
      fram_we   = 1'b0;
      fram_addr = frame_rd_addr_i;
    end
  end

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      S_RECV: begin
        if (word_accept && s_axis_tlast) begin
          if (s_axis_tuser) state_d = S_RECV; // error: drop, no alloc needed
          else               state_d = S_ALLOC_WAIT;
        end
      end
      S_ALLOC_WAIT: begin
        if (alloc_gnt_i) state_d = S_DMA_REQ;
      end
      S_DMA_REQ: begin
        if (frame_gnt_i) state_d = S_DMA_SERVE;
      end
      S_DMA_SERVE: begin
        if (frame_dma_done_i) state_d = S_ENQ_WAIT;
      end
      S_ENQ_WAIT: begin
        if (dest_mask_valid_i && enqueue_gnt_i) state_d = S_RECV;
      end
      default: state_d = S_RECV;
    endcase
  end

endmodule
