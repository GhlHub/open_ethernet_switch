// buf_mgr_pkg.sv
//
// Shared parameters and memory layout for the switch buffer manager.
//
// Scope of this package/RTL: the control-plane core only -- the free list,
// per-buffer refcount/length, and the 6 per-port linked-list queues. It
// does NOT include the AXI4 DMA engines that move payload bytes to/from PS
// DDR, or the CPU-facing AXI-Lite/stream register interface -- those
// consume/produce this core's alloc/enqueue/dequeue/release handshakes and
// are a separate, later piece of RTL.
//
// Port numbering: 0-3 = PS GEM0/1, PL GMII0/1 (order is a convention, not
// load-bearing), 4 = SFP0, 5 = CPU (virtual, no MAC -- bidirectional: it
// both submits frames for forwarding and receives frames punted to it).

package buf_mgr_pkg;

  // ---------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------
  parameter int NUM_PORTS = 6; // 5 physical (PS x2, PL x2, SFP) + 1 CPU

  // NUM_BUFFERS defaults small for simulation turnaround; a real build
  // targeting e.g. NUM_BUFFERS=4096 (with BUFFER_BYTES=2048 -> 8MB of
  // reserved DDR) is a straightforward parameter bump, nothing here
  // assumes this specific value.
  parameter int NUM_BUFFERS   = 256;
  parameter int BUF_ID_W      = $clog2(NUM_BUFFERS);

  parameter int BUFFER_BYTES  = 2048;                     // payload slot size in DDR
  parameter int LENGTH_W      = $clog2(BUFFER_BYTES + 1); // 0..BUFFER_BYTES inclusive

  // refcount must count up to a full flood (every port), so NUM_PORTS is a
  // safe upper bound
  parameter int REFCNT_W = $clog2(NUM_PORTS + 1);

  parameter int PORT_ID_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;

  // rr_arbiter (rtl/common) requires a power-of-two N; NUM_PORTS=6 is not
  // one, so every arbiter in this design is instantiated at ARB_N and the
  // upper (ARB_N-NUM_PORTS) request bits are permanently tied to 0 rather
  // than touching the (already verified) generic arbiter.
  parameter int ARB_N = 1 << $clog2(NUM_PORTS);

  // ---------------------------------------------------------------------
  // Per-buffer state is split across two independently-owned memories,
  // each with a single engine as sole reader/writer (see free_list_mgr.sv
  // and queue_mgr.sv) so neither needs multi-port arbitration internally:
  //
  //   refcount[bufid]                  -- owned by free_list_mgr
  //   length[bufid]                    -- owned by queue_mgr
  //   link[port][bufid] = {valid, next} -- owned by queue_mgr
  //
  // link is per-(port, buffer) rather than a single next-pointer per
  // buffer because a flooded/multicast buffer sits in several ports'
  // queues at once, each at a different position -- one next-pointer per
  // buffer can't represent that, but one per (port, buffer) pair can.
  // ---------------------------------------------------------------------
  parameter int LINK_W = 1 + BUF_ID_W; // {next_valid, next_ptr}

  function automatic logic [LINK_W-1:0] link_pack(input logic next_valid, input logic [BUF_ID_W-1:0] next_ptr);
    return {next_valid, next_ptr};
  endfunction

endpackage
