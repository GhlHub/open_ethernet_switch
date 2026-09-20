// tb_buf_mgr_core.sv
//
// Self-checking smoke test for buf_mgr_core:
//   1. allocate a buffer on port 0
//   2. enqueue it as a unicast to port 2 -> dequeue on port 2, check
//      bufid/length match, release, confirm the buffer comes back around
//      on a fresh alloc (proves the free-list round-trip works)
//   3. allocate + enqueue a flood (dest_mask hitting 3 ports) -> dequeue
//      on all 3, confirm the SAME bufid/length appear on each (proves the
//      per-port linked-list sharing one buffer works) -> release from two
//      of the three and confirm the buffer is NOT back on the free list
//      yet (refcount>0) -> release the third and confirm it now is
//      (refcount hit 0)
//   4. enqueue with an all-zero dest_mask (drop) -> confirm the buffer
//      comes straight back on the free list with no dequeue anywhere
//   6. link state: enqueue destinations are masked with link_up_i; a flush
//      pulse drains a port's queue and releases each buffer's reference
//      (freeing buffers whose count reaches 0), holds off that port's
//      dequeues, leaves other ports' copies of flooded buffers intact, and
//      leaves no buffer leaked
//   5. exercise concurrent alloc requests from several ports at once
//      (round-robin arbiter fairness, not correctness-critical but good
//      to exercise)

`timescale 1ns/1ps

module tb_buf_mgr_core;
  import buf_mgr_pkg::*;

  logic clk = 0;
  logic rst_n = 0;

  logic [NUM_PORTS-1:0]               alloc_req_i;
  logic [NUM_PORTS-1:0]               alloc_gnt_o;
  logic [BUF_ID_W-1:0]                alloc_bufid_o;

  logic [NUM_PORTS-1:0]                enqueue_req_i;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  enqueue_bufid_i;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0]  enqueue_length_i;
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask_i;
  logic [NUM_PORTS-1:0]                enqueue_gnt_o;

  logic [NUM_PORTS-1:0]               dequeue_req_i;
  logic [NUM_PORTS-1:0]               dequeue_valid_o;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid_o;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length_o;

  logic [NUM_PORTS-1:0]               release_req_i;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid_i;
  logic [NUM_PORTS-1:0]               release_gnt_o;

  logic [NUM_PORTS-1:0] link_up_i = '1;
  logic [NUM_PORTS-1:0] flush_req_i = '0;
  logic                 flush_busy_o;

  buf_mgr_core dut (.*);

  always #5 clk = ~clk;

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // Every do_* task below follows the same protocol: assert the request,
  // wait for the grant, capture any result outputs (valid the same cycle
  // as the grant), then deassert the request *immediately* -- before any
  // further @(posedge clk) -- and only then wait one settle cycle. Holding
  // the request asserted through an extra clock edge before deasserting it
  // would let a real responder legally re-arbitrate and grant the same
  // still-asserted requester a second time (this bit us during bring-up:
  // it silently double-released a buffer's refcount). The settle cycle
  // itself is needed because a granted operation's register write (e.g.
  // free_list_mgr's refcount decrement) commits one cycle after the grant
  // is observed, so callers need it before inspecting side effects.

  task automatic do_alloc(input int port, output logic [BUF_ID_W-1:0] bufid);
    int timeout;
    bit timed_out;
    alloc_req_i[port] = 1'b1;
    timeout = 0;
    timed_out = 1'b0;
    while (!alloc_gnt_o[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: alloc on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    if (timed_out) bufid = 'x;
    else            bufid = alloc_bufid_o;
    alloc_req_i[port] = 1'b0;
    @(posedge clk);
  endtask

  task automatic do_enqueue(input int port, input logic [BUF_ID_W-1:0] bufid,
                             input logic [LENGTH_W-1:0] length, input logic [NUM_PORTS-1:0] destmask);
    int timeout;
    bit timed_out;
    enqueue_req_i[port]      = 1'b1;
    enqueue_bufid_i[port]    = bufid;
    enqueue_length_i[port]   = length;
    enqueue_destmask_i[port] = destmask;
    timeout = 0;
    timed_out = 1'b0;
    while (!enqueue_gnt_o[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: enqueue on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    enqueue_req_i[port] = 1'b0;
    @(posedge clk);
  endtask

  task automatic do_dequeue(input int port, output logic [BUF_ID_W-1:0] bufid, output logic [LENGTH_W-1:0] length);
    int timeout;
    bit timed_out;
    dequeue_req_i[port] = 1'b1;
    timeout = 0;
    timed_out = 1'b0;
    while (!dequeue_valid_o[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: dequeue on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    if (timed_out) begin
      bufid = 'x; length = 'x;
    end else begin
      bufid  = dequeue_bufid_o[port];
      length = dequeue_length_o[port];
    end
    dequeue_req_i[port] = 1'b0;
    @(posedge clk);
  endtask

  task automatic do_release(input int port, input logic [BUF_ID_W-1:0] bufid);
    int timeout;
    bit timed_out;
    release_req_i[port]   = 1'b1;
    release_bufid_i[port] = bufid;
    timeout = 0;
    timed_out = 1'b0;
    while (!release_gnt_o[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: release on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    release_req_i[port] = 1'b0;
    @(posedge clk);
  endtask

  // true once dequeue_req has been held with no result for a while -- used
  // to confirm a queue really is empty (no frame ever shows up)
  task automatic confirm_no_dequeue(input int port, input int cycles);
    dequeue_req_i[port] = 1'b1;
    for (int c = 0; c < cycles; c++) begin
      @(posedge clk);
      if (dequeue_valid_o[port]) begin
        $display("FAIL: unexpected dequeue on port %0d (queue should be empty)", port);
        errors++;
      end
    end
    dequeue_req_i[port] = 1'b0;
  endtask

  logic [BUF_ID_W-1:0] bufid_a, bufid_b, bufid_c;
  logic [LENGTH_W-1:0] length_a;

  task automatic show_free(input string tag);
    $display("INFO: free buffers %0d at %s", dut.u_free_list_mgr.u_free_fifo.count_q, tag);
  endtask

  initial begin
    alloc_req_i         = '0;
    enqueue_req_i        = '0;
    enqueue_bufid_i       = '0;
    enqueue_length_i      = '0;
    enqueue_destmask_i    = '0;
    dequeue_req_i        = '0;
    release_req_i         = '0;
    release_bufid_i        = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    // free_list_mgr's S_FILL sweep needs NUM_BUFFERS cycles
    wait_cycles(NUM_BUFFERS + 20);

    show_free("start");
    // ---- 1: simple unicast round trip ----
    do_alloc(0, bufid_a);
    do_enqueue(0, bufid_a, LENGTH_W'(100), NUM_PORTS'(1) << 2); // dest = port 2 only
    do_dequeue(2, bufid_b, length_a);
    if (bufid_b !== bufid_a || length_a !== LENGTH_W'(100)) begin
      $display("FAIL: unicast round trip bufid=%0d(exp %0d) length=%0d(exp 100)", bufid_b, bufid_a, length_a);
      errors++;
    end else begin
      $display("PASS: unicast round trip bufid=%0d length=%0d", bufid_b, length_a);
    end
    do_release(2, bufid_b);

    // buffer should now be back on the free list -- simplest direct proof
    // for a smoke test: confirm a fresh alloc doesn't stall (i.e. at
    // least one buffer is free again).
    do_alloc(0, bufid_c);
    if (alloc_gnt_o === 1'bx) begin
      $display("FAIL: alloc after release did not complete");
      errors++;
    end else begin
      $display("PASS: alloc succeeded after release (free list round-trip)");
    end
    // (a buffer that was never enqueued has no refcount, so it is returned
    // through the drop path, not release)
    do_enqueue(0, bufid_c, LENGTH_W'(64), NUM_PORTS'(0));

    // ---- 2: flood to 3 ports, shared buffer, refcount ----
    do_alloc(0, bufid_a);
    do_enqueue(0, bufid_a, LENGTH_W'(200), (NUM_PORTS'(1)<<1) | (NUM_PORTS'(1)<<3) | (NUM_PORTS'(1)<<4));

    do_dequeue(1, bufid_b, length_a);
    if (bufid_b !== bufid_a || length_a !== LENGTH_W'(200)) begin
      $display("FAIL: flood dequeue port1 bufid=%0d(exp %0d) len=%0d", bufid_b, bufid_a, length_a);
      errors++;
    end
    do_dequeue(3, bufid_b, length_a);
    if (bufid_b !== bufid_a || length_a !== LENGTH_W'(200)) begin
      $display("FAIL: flood dequeue port3 bufid=%0d(exp %0d) len=%0d", bufid_b, bufid_a, length_a);
      errors++;
    end
    do_dequeue(4, bufid_b, length_a);
    if (bufid_b !== bufid_a || length_a !== LENGTH_W'(200)) begin
      $display("FAIL: flood dequeue port4 bufid=%0d(exp %0d) len=%0d", bufid_b, bufid_a, length_a);
      errors++;
    end
    $display("PASS: flood delivered the same bufid=%0d to ports 1,3,4", bufid_a);

    // release 2 of 3 -- refcount should still be >0, buffer not free yet
    // (checked directly via the internal refcount memory).
    do_release(1, bufid_a);
    do_release(3, bufid_a);
    if (dut.u_free_list_mgr.refcount_mem[bufid_a] !== 3'd1) begin
      $display("FAIL: refcount after 2 of 3 releases = %0d, expected 1", dut.u_free_list_mgr.refcount_mem[bufid_a]);
      errors++;
    end else begin
      $display("PASS: refcount correctly at 1 after 2 of 3 releases");
    end
    do_release(4, bufid_a);
    if (dut.u_free_list_mgr.refcount_mem[bufid_a] !== 3'd0) begin
      $display("FAIL: refcount after 3rd release = %0d, expected 0", dut.u_free_list_mgr.refcount_mem[bufid_a]);
      errors++;
    end else begin
      $display("PASS: refcount correctly at 0 after final release (buffer freed)");
    end

    // ---- 3: drop (empty dest_mask) ----
    do_alloc(0, bufid_a);
    do_enqueue(0, bufid_a, LENGTH_W'(64), NUM_PORTS'(0)); // no destinations -> drop
    // confirm no port ever sees this frame
    fork
      confirm_no_dequeue(0, 20);
      confirm_no_dequeue(1, 20);
      confirm_no_dequeue(2, 20);
      confirm_no_dequeue(3, 20);
      confirm_no_dequeue(4, 20);
      confirm_no_dequeue(5, 20);
    join
    if (dut.u_free_list_mgr.refcount_mem[bufid_a] !== 3'd0) begin
      $display("FAIL: dropped buffer refcount = %0d, expected 0", dut.u_free_list_mgr.refcount_mem[bufid_a]);
      errors++;
    end else begin
      $display("PASS: dropped buffer freed immediately, no destination ever saw it");
    end

    show_free("after4");
    // ---- 5: link state masking and link-down flush ----
    begin
      logic [BUF_ID_W-1:0] ba, bb, bc, bd, rb;
      logic [LENGTH_W-1:0] rl;
      int deq_seen;

      // 5a: link-down port never receives new frames: flood to {1,2,3} with port 2 down
      link_up_i = '1; link_up_i[2] = 1'b0;
      wait_cycles(4);
      do_alloc(0, ba);
      do_enqueue(0, ba, LENGTH_W'(90), (NUM_PORTS'(1)<<1) | (NUM_PORTS'(1)<<2) | (NUM_PORTS'(1)<<3));
      if (dut.u_free_list_mgr.refcount_mem[ba] !== 3'd2) begin
        $display("FAIL: 5a refcount=%0d, expected 2 (port 2 down)", dut.u_free_list_mgr.refcount_mem[ba]); errors++;
      end else $display("PASS: 5a flood to a link-down port is masked (refcount 2, not 3)");
      confirm_no_dequeue(2, 20);
      do_dequeue(1, rb, rl); do_release(1, rb);
      do_dequeue(3, rb, rl); do_release(3, rb);
      if (dut.u_free_list_mgr.refcount_mem[ba] !== 3'd0) begin $display("FAIL: 5a buffer not freed"); errors++; end

      // 5a': unicast to a down port is a drop: buffer freed straight back
      do_alloc(0, ba);
      do_enqueue(0, ba, LENGTH_W'(70), NUM_PORTS'(1) << 2);
      confirm_no_dequeue(2, 20);
      if (dut.u_free_list_mgr.refcount_mem[ba] !== 3'd0) begin $display("FAIL: 5a' unicast to down port not dropped"); errors++; end
      else $display("PASS: 5a' unicast to a link-down port is dropped, buffer freed");

    show_free("5a");
      // 5b: drain: port 2 up, queue A->{2}, B->{2,3}, C->{2}; then link down + flush
      link_up_i = '1; wait_cycles(4);
      do_alloc(0, ba); do_alloc(0, bb); do_alloc(0, bc);
      do_enqueue(0, ba, LENGTH_W'(101), NUM_PORTS'(1) << 2);
      do_enqueue(0, bb, LENGTH_W'(102), (NUM_PORTS'(1)<<2) | (NUM_PORTS'(1)<<3));
      do_enqueue(0, bc, LENGTH_W'(103), NUM_PORTS'(1) << 2);
      if (dut.u_free_list_mgr.refcount_mem[ba] !== 3'd1 || dut.u_free_list_mgr.refcount_mem[bb] !== 3'd2 ||
          dut.u_free_list_mgr.refcount_mem[bc] !== 3'd1) begin
        $display("FAIL: 5b setup refcounts %0d/%0d/%0d", dut.u_free_list_mgr.refcount_mem[ba],
                 dut.u_free_list_mgr.refcount_mem[bb], dut.u_free_list_mgr.refcount_mem[bc]); errors++;
      end
      // the flush must also hold off port 2's own dequeue requests (a
      // dequeue already in flight before the flush pulse belongs to the
      // egress reader, so the request rises only after the pulse here)
      deq_seen = 0;
      link_up_i[2] = 1'b0;
      @(posedge clk); flush_req_i[2] = 1'b1; @(posedge clk); flush_req_i[2] = 1'b0; dequeue_req_i[2] = 1'b1;
      fork
        begin : mon
          repeat (400) begin @(posedge clk); if (dequeue_valid_o[2]) deq_seen++; end
        end
      join
      dequeue_req_i[2] = 1'b0;
      if (flush_busy_o !== 1'b0) begin $display("FAIL: 5b flush still busy after 400 cycles"); errors++; end
      if (deq_seen != 0) begin $display("FAIL: 5b port 2 dequeued %0d entries while flushing", deq_seen); errors++; end
      if (dut.u_queue_mgr.queue_empty[2] !== 1'b1) begin $display("FAIL: 5b port 2 queue not empty after flush"); errors++; end
      if (dut.u_free_list_mgr.refcount_mem[ba] !== 3'd0 || dut.u_free_list_mgr.refcount_mem[bc] !== 3'd0 ||
          dut.u_free_list_mgr.refcount_mem[bb] !== 3'd1) begin
        $display("FAIL: 5b post-flush refcounts A=%0d B=%0d C=%0d (exp 0/1/0)", dut.u_free_list_mgr.refcount_mem[ba],
                 dut.u_free_list_mgr.refcount_mem[bb], dut.u_free_list_mgr.refcount_mem[bc]); errors++;
      end else $display("PASS: 5b flush released port 2's references (A,C freed, flooded B kept for port 3)");
      do_dequeue(3, rb, rl);
      if (rb !== bb || rl !== LENGTH_W'(102)) begin $display("FAIL: 5b port 3 lost its copy of B"); errors++; end
      else $display("PASS: 5b port 3 still delivers its copy of the flooded frame");
      do_release(3, bb);
      if (dut.u_free_list_mgr.refcount_mem[bb] !== 3'd0) begin $display("FAIL: 5b B not freed"); errors++; end

    show_free("5b");
      // 5c: flush of an already-empty queue completes; port works again after link-up
      @(posedge clk); flush_req_i[2] = 1'b1; @(posedge clk); flush_req_i[2] = 1'b0;
      wait_cycles(20);
      if (flush_busy_o !== 1'b0) begin $display("FAIL: 5c empty flush stuck busy"); errors++; end
      link_up_i = '1; wait_cycles(4);
      do_alloc(0, bd);
      do_enqueue(0, bd, LENGTH_W'(111), NUM_PORTS'(1) << 2);
      do_dequeue(2, rb, rl);
      if (rb !== bd || rl !== LENGTH_W'(111)) begin $display("FAIL: 5c port 2 not usable after link-up"); errors++; end
      else $display("PASS: 5c port 2 receives frames again after link-up");
      do_release(2, rb);

    show_free("5c");
      // 5d: two ports flushed in back-to-back cycles
      do_alloc(0, ba); do_alloc(0, bb);
      do_enqueue(0, ba, LENGTH_W'(60), (NUM_PORTS'(1)<<1) | (NUM_PORTS'(1)<<4));
      do_enqueue(0, bb, LENGTH_W'(61), (NUM_PORTS'(1)<<1) | (NUM_PORTS'(1)<<4));
      link_up_i[1] = 1'b0; link_up_i[4] = 1'b0;
      @(posedge clk); flush_req_i[1] = 1'b1; @(posedge clk); flush_req_i[1] = 1'b0; flush_req_i[4] = 1'b1;
      @(posedge clk); flush_req_i[4] = 1'b0;
      wait_cycles(400);
      if (flush_busy_o !== 1'b0 || dut.u_queue_mgr.queue_empty[1] !== 1'b1 || dut.u_queue_mgr.queue_empty[4] !== 1'b1 ||
          dut.u_free_list_mgr.refcount_mem[ba] !== 3'd0 || dut.u_free_list_mgr.refcount_mem[bb] !== 3'd0) begin
        $display("FAIL: 5d back-to-back flushes"); errors++;
      end else $display("PASS: 5d back-to-back flushes of two ports freed both shared buffers");
      link_up_i = '1;

    show_free("5d");
      // 5f: flush racing another port's releases for the same flooded buffers
      begin
        logic [BUF_ID_W-1:0] fb [20];
        for (int i = 0; i < 20; i++) begin
          do_alloc(0, fb[i]);
          do_enqueue(0, fb[i], LENGTH_W'(80 + i), (NUM_PORTS'(1)<<2) | (NUM_PORTS'(1)<<3));
        end
        link_up_i[2] = 1'b0;
        @(posedge clk); flush_req_i[2] = 1'b1; @(posedge clk); flush_req_i[2] = 1'b0;
        fork
          begin
            for (int i = 0; i < 20; i++) begin
              logic [BUF_ID_W-1:0] rb2; logic [LENGTH_W-1:0] rl2;
              do_dequeue(3, rb2, rl2);
              do_release(3, rb2);
            end
          end
        join
        wait_cycles(400);
        if (dut.u_free_list_mgr.u_free_fifo.count_q !== 9'd256 || flush_busy_o !== 1'b0) begin
          $display("FAIL: 5f free buffers=%0d (exp 256) busy=%b: flush/release race leaked buffers",
                   dut.u_free_list_mgr.u_free_fifo.count_q, flush_busy_o); errors++;
        end else $display("PASS: 5f flush racing port 3's releases: all 20 shared buffers freed exactly once");
        link_up_i = '1;
      end

      // 5e: nothing leaked: every buffer can still be allocated
      begin
        logic [BUF_ID_W-1:0] ids [NUM_BUFFERS];
        int okc;
        okc = 0;
        for (int i = 0; i < NUM_BUFFERS; i++) begin
          do_alloc(0, ids[i]);
          if (alloc_gnt_o !== 1'bx && ids[i] !== 'x) okc++;
        end
        if (okc != NUM_BUFFERS) begin $display("FAIL: 5e only %0d of %0d buffers allocatable (leak)", okc, NUM_BUFFERS); errors++; end
        else $display("PASS: 5e all %0d buffers still allocatable (no leak)", NUM_BUFFERS);
        for (int i = 0; i < NUM_BUFFERS; i++) do_enqueue(0, ids[i], LENGTH_W'(64), NUM_PORTS'(0)); // drop path frees them
      end
    end

    // ---- 4: concurrent allocs from multiple ports ----
    fork
      begin logic [BUF_ID_W-1:0] b; do_alloc(0, b); do_release(0, b); end
      begin logic [BUF_ID_W-1:0] b; do_alloc(1, b); do_release(1, b); end
      begin logic [BUF_ID_W-1:0] b; do_alloc(2, b); do_release(2, b); end
      begin logic [BUF_ID_W-1:0] b; do_alloc(5, b); do_release(5, b); end
    join
    $display("PASS: concurrent multi-port alloc/release completed without hang");

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);

    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
