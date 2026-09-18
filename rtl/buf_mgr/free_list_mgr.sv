// free_list_mgr.sv
//
// Owns the free-buffer-ID FIFO and the per-buffer refcount table. Three
// operation types, serialized through one small engine:
//   - alloc   (NUM_PORTS requesters): pop a free buffer ID
//   - release (NUM_PORTS requesters): decrement a buffer's refcount;
//     return it to the free list once the count reaches 0
//   - setref  (single caller: queue_mgr): initialize a buffer's refcount
//     when it is first enqueued to >=1 destination
//   - direct_free (single caller: queue_mgr): push a buffer straight back
//     onto the free list with no refcount involved at all, used only for
//     the "drop" case (enqueue with no destinations, e.g. a lookup miss
//     with no flood policy, or a CRC error) -- the buffer was never given
//     a refcount, so a decrement-based release makes no sense for it
//
// Priority when more than one op wants attention this cycle: setref/
// direct_free (mutually exclusive, both from queue_mgr) > release > alloc.
// The queue_mgr ops go first since that engine synchronously blocks on
// the ack; release goes before alloc since freeing buffers helps whoever
// is waiting to allocate.
//
// At reset, every buffer ID is pushed onto the free list (S_FILL) before
// normal operation (S_IDLE) begins -- refcount_mem also starts all-zero,
// consistent with every buffer being unused.

module free_list_mgr
  import buf_mgr_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // alloc
  input  logic [NUM_PORTS-1:0]               alloc_req_i,
  output logic [NUM_PORTS-1:0]               alloc_gnt_o,   // one-hot pulse
  output logic [BUF_ID_W-1:0]                alloc_bufid_o, // valid when |alloc_gnt_o

  // release
  input  logic [NUM_PORTS-1:0]               release_req_i,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid_i,
  output logic [NUM_PORTS-1:0]               release_gnt_o, // one-hot pulse

  // setref (single caller: queue_mgr)
  input  logic                 setref_req_i,
  input  logic [BUF_ID_W-1:0]  setref_bufid_i,
  input  logic [REFCNT_W-1:0]  setref_count_i,
  output logic                 setref_gnt_o,

  // direct_free (single caller: queue_mgr, drop path)
  input  logic                 direct_free_req_i,
  input  logic [BUF_ID_W-1:0]  direct_free_bufid_i,
  output logic                 direct_free_gnt_o
);

  // ---- free list FIFO ----
  logic                 fifo_wr_en, fifo_rd_en, fifo_full, fifo_empty;
  logic [BUF_ID_W-1:0]  fifo_wr_data, fifo_rd_data;

  sync_fifo #(.WIDTH(BUF_ID_W), .DEPTH(NUM_BUFFERS)) u_free_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- refcount memory (single owner -> a single port is enough) ----
  logic [REFCNT_W-1:0] refcount_mem [0:NUM_BUFFERS-1];
  logic                 rc_en, rc_we;
  logic [BUF_ID_W-1:0]  rc_addr;
  logic [REFCNT_W-1:0]  rc_wdata;
  logic [REFCNT_W-1:0]  rc_rdata_q;

  initial begin
    for (int i = 0; i < NUM_BUFFERS; i++) refcount_mem[i] = '0;
  end

  always_ff @(posedge clk) begin
    if (rc_en) begin
      if (rc_we) refcount_mem[rc_addr] <= rc_wdata;
      rc_rdata_q <= refcount_mem[rc_addr];
    end
  end

  // ---- port arbiters (padded to ARB_N; upper request bits tied 0) ----
  logic [ARB_N-1:0] alloc_grant_p, release_grant_p;
  logic             alloc_valid, release_valid;

  rr_arbiter #(.N(ARB_N)) u_alloc_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(ARB_N-NUM_PORTS){1'b0}}, alloc_req_i} & {ARB_N{~fifo_empty}}),
    .grant_o (alloc_grant_p),
    .valid_o (alloc_valid)
  );

  rr_arbiter #(.N(ARB_N)) u_release_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(ARB_N-NUM_PORTS){1'b0}}, release_req_i}),
    .grant_o (release_grant_p),
    .valid_o (release_valid)
  );

  wire [NUM_PORTS-1:0] alloc_grant   = alloc_grant_p[NUM_PORTS-1:0];
  wire [NUM_PORTS-1:0] release_grant = release_grant_p[NUM_PORTS-1:0];

  logic [BUF_ID_W-1:0] release_bufid_muxed;
  always_comb begin
    release_bufid_muxed = '0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (release_grant[p]) release_bufid_muxed = release_bufid_i[p];
    end
  end

  // ---- sequencer ----
  typedef enum logic [1:0] {S_FILL, S_IDLE, S_RELEASE_WRITE} state_t;
  state_t state_q, state_d;

  logic [BUF_ID_W-1:0]  fill_cnt_q;
  logic [BUF_ID_W-1:0]  release_bufid_q;
  logic [NUM_PORTS-1:0] release_grant_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_FILL;
      fill_cnt_q <= '0;
    end else begin
      state_q <= state_d;
      if (state_q == S_FILL) fill_cnt_q <= fill_cnt_q + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (state_q == S_IDLE && !setref_req_i && !direct_free_req_i && release_valid) begin
      release_bufid_q <= release_bufid_muxed;
      release_grant_q <= release_grant;
    end
  end

  // Priority winner conditions, and every output this module drives to the
  // OUTSIDE world (setref_gnt_o/direct_free_gnt_o/alloc_gnt_o/
  // release_gnt_o/alloc_bufid_o) as plain derived `assign`s rather than
  // being embedded (default-then-conditionally-overridden) inside the
  // sequencer's case-based always_comb below. This split turned out to be
  // load-bearing, not just style: Icarus Verilog 12.0 has a confirmed bug
  // where a grant signal computed by an if/case-based always_comb, fed
  // into another module whose own if/case-based always_comb reads it (and
  // whose *output* this module's always_comb in turn reads -- a mutual
  // dependency that is completely acyclic in final settled value, exactly
  // the shape every req/gnt handshake in this codebase has), can produce a
  // genuine delta-cycle livelock. It does not reproduce when the grant
  // side is a simple continuous assignment (as bank_arbiter.sv's
  // `assign learn_gnt_o = (state_q == S_LEARN);` already was, which is
  // why that handshake never hit this). Internal-only signals (rc_en/we/
  // addr/wdata, fifo controls, state_d) stay in the case statement since
  // nothing outside this module reads them combinationally.
  wire setref_win      = (state_q == S_IDLE) && setref_req_i;
  wire direct_free_win = (state_q == S_IDLE) && !setref_req_i && direct_free_req_i;
  wire release_win     = (state_q == S_IDLE) && !setref_req_i && !direct_free_req_i && release_valid;
  wire alloc_win        = (state_q == S_IDLE) && !setref_req_i && !direct_free_req_i && !release_valid && alloc_valid;

  assign setref_gnt_o      = setref_win;
  assign direct_free_gnt_o = direct_free_win;
  assign alloc_gnt_o       = alloc_win ? alloc_grant : '0;
  assign alloc_bufid_o     = fifo_rd_data;
  assign release_gnt_o     = (state_q == S_RELEASE_WRITE) ? release_grant_q : '0;

  always_comb begin
    state_d      = state_q;
    fifo_wr_en   = 1'b0;
    fifo_wr_data = fill_cnt_q;
    fifo_rd_en   = 1'b0;
    rc_en        = 1'b0;
    rc_we        = 1'b0;
    rc_addr      = '0;
    rc_wdata     = '0;

    unique case (state_q)
      S_FILL: begin
        fifo_wr_en = 1'b1; // push fill_cnt_q; NUM_BUFFERS pushes exactly fills the FIFO
        if (fill_cnt_q == BUF_ID_W'(NUM_BUFFERS-1)) state_d = S_IDLE;
      end
      S_IDLE: begin
        if (setref_win) begin
          rc_en    = 1'b1;
          rc_we    = 1'b1;
          rc_addr  = setref_bufid_i;
          rc_wdata = setref_count_i;
        end else if (direct_free_win) begin
          fifo_wr_en   = 1'b1;
          fifo_wr_data = direct_free_bufid_i;
        end else if (release_win) begin
          rc_en   = 1'b1;
          rc_we   = 1'b0;
          rc_addr = release_bufid_muxed;
          state_d = S_RELEASE_WRITE;
        end else if (alloc_win) begin
          fifo_rd_en = 1'b1;
        end
      end
      S_RELEASE_WRITE: begin
        rc_en    = 1'b1;
        rc_we    = 1'b1;
        rc_addr  = release_bufid_q;
        rc_wdata = rc_rdata_q - 1'b1;
        if (rc_rdata_q == REFCNT_W'(1)) begin
          // decrementing from 1 -> 0: return to free list
          fifo_wr_en   = 1'b1;
          fifo_wr_data = release_bufid_q;
        end
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
