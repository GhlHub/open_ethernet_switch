// queue_mgr.sv
//
// Owns the per-buffer length and the 6 per-port linked-list queues, and
// talks to free_list_mgr to set/clear refcounts. One serialized engine
// handles two operation types, alternating fairly between them when both
// have pending work:
//
//   enqueue (NUM_PORTS submitters): given {bufid, length, dest_mask},
//     record the length, set the buffer's refcount to popcount(dest_mask)
//     (or, if dest_mask is all-zero -- a drop -- free the buffer straight
//     back via free_list_mgr's direct_free op instead), then append bufid
//     to the tail of every destination port's queue whose bit is set.
//
//   dequeue (NUM_PORTS consumers): pop the head of the requesting port's
//     own queue (each port's queue is independent, no cross-port
//     arbitration needed for *which* queue -- only for access to the
//     shared link/length memories if more than one consumer wants to
//     dequeue the same cycle).
//
// Link-down flush: a one-cycle pulse on flush_req_i[p] marks port p pending.
// The engine (flush has priority over enqueue/dequeue when idle) then drains
// that port's queue one entry at a time -- read the head and its next pointer,
// pop it like a dequeue, and release the buffer's reference through
// free_list_mgr's flush_release path (freeing the buffer when its refcount
// reaches 0) -- until the queue is empty. Dequeue requests from a pending port
// are held off while it drains. Enqueue destinations are always masked with
// link_up_i at capture time, so once a port's link bit is low nothing new is
// queued to it; since the engine is serialized, an enqueue that captured the
// old mask completes before the flush starts and is drained by it.
//
// Per-port queues are singly-linked lists threaded through a per-(port,
// buffer) link table (link_mem), NOT a single next-pointer per buffer --
// a flooded/multicast buffer sits in several ports' queues at once, each
// at a different position, so one next-pointer per buffer can't represent
// that. head_ptr/tail_ptr/queue_empty are small per-port registers, not
// memory.
//
// Appending to a non-empty queue costs 2 link_mem write cycles (the old
// tail's next-pointer, then the new entry's own now-empty next-pointer);
// an empty queue costs 1. This is bookkeeping, not the data path, so the
// extra cycle per flood destination is irrelevant to real throughput.

module queue_mgr
  import buf_mgr_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // enqueue (NUM_PORTS submitters)
  input  logic [NUM_PORTS-1:0]                enqueue_req_i,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  enqueue_bufid_i,
  input  logic [NUM_PORTS-1:0][LENGTH_W-1:0]  enqueue_length_i,
  input  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask_i,
  // Per-buffer, not per-destination (exactly like enqueue_length_i above):
  // the ingress port a buffer's frame actually arrived on, captured once at
  // enqueue and read back once at dequeue regardless of which port(s) it is
  // delivered to. Ports 0-4 tie this to their own fixed PORT_ID at the
  // ingress_top.sv boundary; only the CPU port (index 5) ever reads it back
  // (see switch_top.sv's cpu_rx_ingress_* ports) -- a hook for any control
  // protocol that needs to know which physical port a CPU-delivered frame
  // came from, not just STP.
  input  logic [NUM_PORTS-1:0][PORT_ID_W-1:0] enqueue_meta_i,
  output logic [NUM_PORTS-1:0]                enqueue_gnt_o, // one-hot pulse

  // dequeue (NUM_PORTS consumers, each pops its own queue)
  input  logic [NUM_PORTS-1:0]                dequeue_req_i,   // level
  output logic [NUM_PORTS-1:0]                dequeue_valid_o, // one-hot pulse
  output logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  dequeue_bufid_o,
  output logic [NUM_PORTS-1:0][LENGTH_W-1:0]  dequeue_length_o,
  output logic [NUM_PORTS-1:0][PORT_ID_W-1:0] dequeue_meta_o,

  // link state / flush
  input  logic [NUM_PORTS-1:0] link_up_i,
  input  logic [NUM_PORTS-1:0] flush_req_i,
  output logic                 flush_busy_o,
  output logic                 flush_rel_req_o,
  output logic [BUF_ID_W-1:0]  flush_rel_bufid_o,
  input  logic                 flush_rel_gnt_i,

  // to free_list_mgr
  output logic                 setref_req_o,
  output logic [BUF_ID_W-1:0]  setref_bufid_o,
  output logic [REFCNT_W-1:0]  setref_count_o,
  input  logic                 setref_gnt_i,

  output logic                 direct_free_req_o,
  output logic [BUF_ID_W-1:0]  direct_free_bufid_o,
  input  logic                 direct_free_gnt_i
);

  // ---- length memory (single owner) ----
  logic [LENGTH_W-1:0] length_mem [0:NUM_BUFFERS-1];
  logic                 len_en, len_we;
  logic [BUF_ID_W-1:0]  len_addr;
  logic [LENGTH_W-1:0]  len_wdata;
  logic [LENGTH_W-1:0]  len_rdata_q;

  always_ff @(posedge clk) begin
    if (len_en) begin
      if (len_we) length_mem[len_addr] <= len_wdata;
      len_rdata_q <= length_mem[len_addr];
    end
  end

  // ---- meta memory (ingress-port tag; single owner, shares length_mem's
  // enable/write/address controls -- always written and read on exactly the
  // same cycles as length, so no separate control signals are needed) ----
  logic [PORT_ID_W-1:0] meta_mem [0:NUM_BUFFERS-1];
  logic [PORT_ID_W-1:0] meta_wdata;
  logic [PORT_ID_W-1:0] meta_rdata_q;

  always_ff @(posedge clk) begin
    if (len_en) begin
      if (len_we) meta_mem[len_addr] <= meta_wdata;
      meta_rdata_q <= meta_mem[len_addr];
    end
  end

  // ---- link memory: one next-pointer per (port, buffer) pair ----
  localparam int LINK_DEPTH = (1 << PORT_ID_W) * NUM_BUFFERS;
  logic [LINK_W-1:0] link_mem [0:LINK_DEPTH-1];
  logic                          lnk_en, lnk_we;
  logic [PORT_ID_W+BUF_ID_W-1:0] lnk_addr;
  logic [LINK_W-1:0]             lnk_wdata;
  logic [LINK_W-1:0]             lnk_rdata_q;

  always_ff @(posedge clk) begin
    if (lnk_en) begin
      if (lnk_we) link_mem[lnk_addr] <= lnk_wdata;
      lnk_rdata_q <= link_mem[lnk_addr];
    end
  end

  // ---- per-port queue state (plain registers, not memory) ----
  logic [BUF_ID_W-1:0] head_ptr [NUM_PORTS];
  logic [BUF_ID_W-1:0] tail_ptr [NUM_PORTS];
  logic                 queue_empty [NUM_PORTS];
  // NUM_PORTS is architecturally fixed at 6 (5 physical + CPU), so this is
  // hand-unrolled via concatenation rather than a procedural for-loop
  // writing individual bit positions of queue_empty_vec: Icarus Verilog
  // 12.0 has a confirmed bug (see rtl/mac_table's aging_sweep_fsm.sv for
  // the full writeup) where such a loop silently corrupts the vector and
  // can produce a genuine simulation livelock, not just a wrong value.
  wire [NUM_PORTS-1:0] queue_empty_vec =
    {queue_empty[5], queue_empty[4], queue_empty[3], queue_empty[2], queue_empty[1], queue_empty[0]};

  // ---- link-down flush bookkeeping ----
  logic [NUM_PORTS-1:0] flush_pend_q;
  logic                 fl_valid;
  logic [PORT_ID_W-1:0] fl_port;
  always_comb begin
    fl_valid = 1'b0;
    fl_port  = '0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (!fl_valid && flush_pend_q[p] && !queue_empty_vec[p]) begin
        fl_valid = 1'b1;
        fl_port  = PORT_ID_W'(p);
      end
    end
  end

  // ---- port arbiters (padded to ARB_N; upper bits tied 0) ----
  logic [ARB_N-1:0] enq_grant_p, deq_grant_p;
  logic             enq_valid, deq_valid;

  rr_arbiter #(.N(ARB_N)) u_enq_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(ARB_N-NUM_PORTS){1'b0}}, enqueue_req_i}),
    .grant_o (enq_grant_p),
    .valid_o (enq_valid)
  );

  rr_arbiter #(.N(ARB_N)) u_deq_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   ({{(ARB_N-NUM_PORTS){1'b0}}, (dequeue_req_i & ~queue_empty_vec & ~flush_pend_q)}),
    .grant_o (deq_grant_p),
    .valid_o (deq_valid)
  );

  wire [NUM_PORTS-1:0] enq_grant = enq_grant_p[NUM_PORTS-1:0];
  wire [NUM_PORTS-1:0] deq_grant = deq_grant_p[NUM_PORTS-1:0];

  logic [BUF_ID_W-1:0]  enq_bufid_muxed;
  logic [LENGTH_W-1:0]  enq_length_muxed;
  logic [NUM_PORTS-1:0] enq_destmask_muxed;
  logic [PORT_ID_W-1:0] enq_meta_muxed;
  always_comb begin
    enq_bufid_muxed    = '0;
    enq_length_muxed   = '0;
    enq_destmask_muxed = '0;
    enq_meta_muxed     = '0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (enq_grant[p]) begin
        enq_bufid_muxed    = enqueue_bufid_i[p];
        enq_length_muxed   = enqueue_length_i[p];
        enq_destmask_muxed = enqueue_destmask_i[p];
        enq_meta_muxed     = enqueue_meta_i[p];
      end
    end
  end

  logic [PORT_ID_W-1:0] deq_port_muxed;
  always_comb begin
    deq_port_muxed = '0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (deq_grant[p]) deq_port_muxed = PORT_ID_W'(p);
    end
  end

  // popcount of a destmask -> initial refcount
  function automatic logic [REFCNT_W-1:0] popcount(input logic [NUM_PORTS-1:0] m);
    logic [REFCNT_W-1:0] c;
    c = '0;
    for (int i = 0; i < NUM_PORTS; i++) c = c + REFCNT_W'(m[i]);
    return c;
  endfunction

  // ---- sequencer ----
  typedef enum logic [3:0] {
    QM_S_IDLE,
    S_ENQ_LEN,
    S_ENQ_REF_WAIT,
    S_ENQ_DROP_WAIT,
    S_ENQ_FIND,
    S_ENQ_LINK_OLDTAIL,
    S_ENQ_LINK_NEW,
    S_ENQ_ACK,
    S_DEQ_READ,
    S_DEQ_COMPLETE,
    S_FL_READ,
    S_FL_COMPLETE,
    S_FL_REL
  } qm_state_t;
  qm_state_t state_q, state_d;

  logic                  last_was_deq_q;

  logic [BUF_ID_W-1:0]   bufid_q;
  logic [LENGTH_W-1:0]   length_q;
  logic [NUM_PORTS-1:0]  destmask_q;
  logic [PORT_ID_W-1:0]  meta_q;
  logic [NUM_PORTS-1:0]  enq_grant_q;
  logic [PORT_ID_W-1:0]  port_idx_q;

  logic [PORT_ID_W-1:0]  deq_port_q;
  logic [NUM_PORTS-1:0]  deq_grant_q;

  logic [PORT_ID_W-1:0]  fl_port_q;
  logic [BUF_ID_W-1:0]   fl_buf_q;

  // find the next set destmask bit at/after port_idx_q -- conditional
  // whole-scalar overwrite in a for loop (verified safe under Icarus
  // Verilog 12.0; the confirmed simulator bug there is specifically about
  // a loop writing different *bit positions* of one shared vector across
  // iterations, which this is not).
  logic                 find_valid;
  logic [PORT_ID_W-1:0] find_port;
  always_comb begin
    find_valid = 1'b0;
    find_port  = '0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (!find_valid && (p >= int'(port_idx_q)) && destmask_q[p]) begin
        find_valid = 1'b1;
        find_port  = PORT_ID_W'(p);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= QM_S_IDLE;
      last_was_deq_q <= 1'b0;
      flush_pend_q   <= '0;
      for (int p = 0; p < NUM_PORTS; p++) queue_empty[p] <= 1'b1;
    end else begin
      state_q <= state_d;

      // pending ports whose queue is already empty are done (whole-vector
      // update only, see the note above on per-bit writes in loops)
      flush_pend_q <= (flush_pend_q & ~(queue_empty_vec & {NUM_PORTS{state_q == QM_S_IDLE}}))
                      | flush_req_i;

      if (state_q == QM_S_IDLE) begin
        if (fl_valid) begin
          fl_port_q <= fl_port;
        end else if (enq_valid && (!deq_valid || last_was_deq_q)) begin
          bufid_q        <= enq_bufid_muxed;
          length_q       <= enq_length_muxed;
          destmask_q     <= enq_destmask_muxed & link_up_i;
          meta_q         <= enq_meta_muxed;
          enq_grant_q    <= enq_grant;
          port_idx_q     <= '0;
          last_was_deq_q <= 1'b0;
        end else if (deq_valid) begin
          deq_port_q     <= deq_port_muxed;
          deq_grant_q    <= deq_grant;
          last_was_deq_q <= 1'b1;
        end
      end

      if (state_q == S_ENQ_FIND && find_valid) begin
        port_idx_q <= find_port;
      end

      // Both blocks below update head_ptr/tail_ptr/queue_empty through a
      // case on a constant index rather than `array[some_register] <= ...`
      // (a variable/register-indexed write into an unpacked array):
      // Icarus Verilog 12.0 has a confirmed bug with variable-indexed
      // writes into a shared vector/array (see the notes elsewhere in
      // this file and in aging_sweep_fsm.sv); this specific variant --
      // register-indexed rather than loop-variable-indexed -- turned out
      // to be an untested case of the same class of bug, not previously
      // caught by the fixes already applied here.
      if (state_q == S_ENQ_LINK_NEW) begin
        // this destination is now committed: update its queue pointers
        unique case (port_idx_q)
          PORT_ID_W'(0): begin if (queue_empty[0]) head_ptr[0] <= bufid_q; tail_ptr[0] <= bufid_q; queue_empty[0] <= 1'b0; end
          PORT_ID_W'(1): begin if (queue_empty[1]) head_ptr[1] <= bufid_q; tail_ptr[1] <= bufid_q; queue_empty[1] <= 1'b0; end
          PORT_ID_W'(2): begin if (queue_empty[2]) head_ptr[2] <= bufid_q; tail_ptr[2] <= bufid_q; queue_empty[2] <= 1'b0; end
          PORT_ID_W'(3): begin if (queue_empty[3]) head_ptr[3] <= bufid_q; tail_ptr[3] <= bufid_q; queue_empty[3] <= 1'b0; end
          PORT_ID_W'(4): begin if (queue_empty[4]) head_ptr[4] <= bufid_q; tail_ptr[4] <= bufid_q; queue_empty[4] <= 1'b0; end
          default:        begin if (queue_empty[5]) head_ptr[5] <= bufid_q; tail_ptr[5] <= bufid_q; queue_empty[5] <= 1'b0; end
        endcase
        port_idx_q <= port_idx_q + 1'b1; // resume scan past this port next time
      end

      if (state_q == S_FL_READ) fl_buf_q <= head_ptr[fl_port_q];

      if (state_q == S_FL_COMPLETE) begin
        unique case (fl_port_q)
          PORT_ID_W'(0): if (lnk_rdata_q[BUF_ID_W]) head_ptr[0] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[0] <= 1'b1;
          PORT_ID_W'(1): if (lnk_rdata_q[BUF_ID_W]) head_ptr[1] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[1] <= 1'b1;
          PORT_ID_W'(2): if (lnk_rdata_q[BUF_ID_W]) head_ptr[2] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[2] <= 1'b1;
          PORT_ID_W'(3): if (lnk_rdata_q[BUF_ID_W]) head_ptr[3] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[3] <= 1'b1;
          PORT_ID_W'(4): if (lnk_rdata_q[BUF_ID_W]) head_ptr[4] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[4] <= 1'b1;
          default:        if (lnk_rdata_q[BUF_ID_W]) head_ptr[5] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[5] <= 1'b1;
        endcase
      end

      if (state_q == S_DEQ_COMPLETE) begin
        unique case (deq_port_q)
          PORT_ID_W'(0): if (lnk_rdata_q[BUF_ID_W]) head_ptr[0] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[0] <= 1'b1;
          PORT_ID_W'(1): if (lnk_rdata_q[BUF_ID_W]) head_ptr[1] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[1] <= 1'b1;
          PORT_ID_W'(2): if (lnk_rdata_q[BUF_ID_W]) head_ptr[2] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[2] <= 1'b1;
          PORT_ID_W'(3): if (lnk_rdata_q[BUF_ID_W]) head_ptr[3] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[3] <= 1'b1;
          PORT_ID_W'(4): if (lnk_rdata_q[BUF_ID_W]) head_ptr[4] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[4] <= 1'b1;
          default:        if (lnk_rdata_q[BUF_ID_W]) head_ptr[5] <= lnk_rdata_q[BUF_ID_W-1:0]; else queue_empty[5] <= 1'b1;
        endcase
      end
    end
  end

  // Boundary-crossing outputs (each consumed by another module's own
  // if/case-based always_comb -- free_list_mgr for setref_req_o/
  // direct_free_req_o, ingress_port_wr for enqueue_gnt_o, egress_port_rd
  // for dequeue_valid_o/dequeue_bufid_o/dequeue_length_o) are computed as
  // plain continuous logic here, driven only by registered state
  // (state_q/deq_port_q/bufid_q/etc), rather than embedded in the
  // sequencer's own case-based always_comb below. Same fix, same
  // rationale, as free_list_mgr.sv's header note: a grant/request signal
  // computed by an if/case-based always_comb, feeding into another
  // module's own if/case-based always_comb whose output feeds back here
  // (enqueue_req_o/dequeue_req_o from ingress_port_wr/egress_port_rd, or
  // setref_gnt_i/direct_free_gnt_i from free_list_mgr), is a confirmed
  // Icarus Verilog delta-cycle livelock/X-propagation risk when the
  // boundary output shares a sensitivity list with those external
  // signals -- even though its *value* never actually depends on them.
  // Internal-only signals (len_*/lnk_* controls, state_d) stay in the big
  // case statement since nothing outside this module reads them
  // combinationally.
  wire setref_win       = (state_q == S_ENQ_REF_WAIT);
  wire direct_free_win  = (state_q == S_ENQ_DROP_WAIT);
  wire enq_ack_win      = (state_q == S_ENQ_ACK);
  wire deq_complete_win = (state_q == S_DEQ_COMPLETE);

  assign setref_req_o        = setref_win;
  assign setref_bufid_o      = bufid_q;
  assign setref_count_o      = popcount(destmask_q);
  assign direct_free_req_o   = direct_free_win;
  assign direct_free_bufid_o = bufid_q;

  assign enqueue_gnt_o = enq_ack_win ? enq_grant_q : '0;

  assign flush_rel_req_o   = (state_q == S_FL_REL);
  assign flush_rel_bufid_o = fl_buf_q;
  assign flush_busy_o      = (|flush_pend_q) || (state_q == S_FL_READ) ||
                             (state_q == S_FL_COMPLETE) || (state_q == S_FL_REL);

  assign dequeue_valid_o = deq_complete_win ? (NUM_PORTS'(1) << deq_port_q) : '0;

  always_comb begin
    dequeue_bufid_o  = '0;
    dequeue_length_o = '0;
    dequeue_meta_o   = '0;
    if (deq_complete_win) begin
      // constant-indexed case, not a variable/register-indexed array
      // write -- see the note atop this file for the confirmed Icarus bug
      // that pattern would hit.
      unique case (deq_port_q)
        PORT_ID_W'(0): begin dequeue_bufid_o[0] = head_ptr[deq_port_q]; dequeue_length_o[0] = len_rdata_q; dequeue_meta_o[0] = meta_rdata_q; end
        PORT_ID_W'(1): begin dequeue_bufid_o[1] = head_ptr[deq_port_q]; dequeue_length_o[1] = len_rdata_q; dequeue_meta_o[1] = meta_rdata_q; end
        PORT_ID_W'(2): begin dequeue_bufid_o[2] = head_ptr[deq_port_q]; dequeue_length_o[2] = len_rdata_q; dequeue_meta_o[2] = meta_rdata_q; end
        PORT_ID_W'(3): begin dequeue_bufid_o[3] = head_ptr[deq_port_q]; dequeue_length_o[3] = len_rdata_q; dequeue_meta_o[3] = meta_rdata_q; end
        PORT_ID_W'(4): begin dequeue_bufid_o[4] = head_ptr[deq_port_q]; dequeue_length_o[4] = len_rdata_q; dequeue_meta_o[4] = meta_rdata_q; end
        default:        begin dequeue_bufid_o[5] = head_ptr[deq_port_q]; dequeue_length_o[5] = len_rdata_q; dequeue_meta_o[5] = meta_rdata_q; end
      endcase
    end
  end

  always_comb begin
    state_d = state_q;

    len_en = 1'b0; len_we = 1'b0; len_addr = '0; len_wdata = '0; meta_wdata = '0;
    lnk_en = 1'b0; lnk_we = 1'b0; lnk_addr = '0; lnk_wdata = '0;

    unique case (state_q)
      QM_S_IDLE: begin
        if (fl_valid)                                       state_d = S_FL_READ;
        else if (enq_valid && (!deq_valid || last_was_deq_q)) state_d = S_ENQ_LEN;
        else if (deq_valid)                                state_d = S_DEQ_READ;
      end

      // ---- enqueue path ----
      // Uses the latched bufid_q/length_q/destmask_q (captured once, on
      // the QM_S_IDLE->S_ENQ_LEN transition), not the live arbiter mux --
      // the arbiter's grant is only meaningful for the single cycle it
      // makes its pick, and its round-robin pointer keeps advancing every
      // cycle req_i is asserted regardless of whether this engine has
      // actually moved on, so re-reading it mid-enqueue could pick up a
      // different requester than the one this operation is for.
      S_ENQ_LEN: begin
        len_en    = 1'b1;
        len_we    = 1'b1;
        len_addr  = bufid_q;
        len_wdata = length_q;
        meta_wdata = meta_q;
        if (destmask_q == '0) state_d = S_ENQ_DROP_WAIT;
        else                   state_d = S_ENQ_REF_WAIT;
      end
      S_ENQ_REF_WAIT: begin
        if (setref_gnt_i) state_d = S_ENQ_FIND;
      end
      S_ENQ_DROP_WAIT: begin
        if (direct_free_gnt_i) state_d = S_ENQ_ACK;
      end
      S_ENQ_FIND: begin
        if (!find_valid) state_d = S_ENQ_ACK; // no destinations left to link
        else if (queue_empty[find_port]) state_d = S_ENQ_LINK_NEW;
        else                               state_d = S_ENQ_LINK_OLDTAIL;
      end
      S_ENQ_LINK_OLDTAIL: begin
        // old tail of this destination's queue now points at bufid_q
        lnk_en   = 1'b1;
        lnk_we   = 1'b1;
        lnk_addr = {port_idx_q, tail_ptr[port_idx_q]};
        lnk_wdata = {1'b1, bufid_q};
        state_d  = S_ENQ_LINK_NEW;
      end
      S_ENQ_LINK_NEW: begin
        // bufid_q's own entry in this destination's queue: no next yet
        lnk_en   = 1'b1;
        lnk_we   = 1'b1;
        lnk_addr = {port_idx_q, bufid_q};
        lnk_wdata = {1'b0, {BUF_ID_W{1'b0}}};
        state_d  = S_ENQ_FIND;
      end
      S_ENQ_ACK: begin
        state_d = QM_S_IDLE;
      end

      // ---- dequeue path ----
      S_DEQ_READ: begin
        len_en   = 1'b1;
        len_we   = 1'b0;
        len_addr = head_ptr[deq_port_q];
        lnk_en   = 1'b1;
        lnk_we   = 1'b0;
        lnk_addr = {deq_port_q, head_ptr[deq_port_q]};
        state_d  = S_DEQ_COMPLETE;
      end
      S_DEQ_COMPLETE: begin
        state_d = QM_S_IDLE;
      end

      // ---- link-down flush of one queue entry ----
      S_FL_READ: begin
        lnk_en   = 1'b1;
        lnk_we   = 1'b0;
        lnk_addr = {fl_port_q, head_ptr[fl_port_q]};
        state_d  = S_FL_COMPLETE;
      end
      S_FL_COMPLETE: begin
        state_d = S_FL_REL;
      end
      S_FL_REL: begin
        if (flush_rel_gnt_i) state_d = QM_S_IDLE;
      end

      default: state_d = QM_S_IDLE;
    endcase
  end

endmodule
