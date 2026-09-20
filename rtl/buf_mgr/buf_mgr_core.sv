// buf_mgr_core.sv
//
// Top-level control-plane core for the switch buffer manager: wires
// free_list_mgr and queue_mgr together and exposes the external
// alloc/enqueue/dequeue/release handshakes, one set of NUM_PORTS each.
//
// This is the control-plane only -- see buf_mgr_pkg.sv. A typical
// ingress front-end (per physical port): alloc -> DMA-write payload to
// DDR while a MAC-table lookup runs -> enqueue with the resulting
// dest_mask. A typical egress front-end: dequeue -> DMA-read payload from
// DDR -> stream to the TX MAC -> release on completion. The CPU port's
// front-end skips the DMA steps entirely (DDR is already CPU-addressable)
// but drives the exact same four handshakes.

module buf_mgr_core
  import buf_mgr_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // alloc (NUM_PORTS requesters)
  input  logic [NUM_PORTS-1:0]               alloc_req_i,
  output logic [NUM_PORTS-1:0]               alloc_gnt_o,
  output logic [BUF_ID_W-1:0]                alloc_bufid_o,

  // enqueue (NUM_PORTS submitters)
  input  logic [NUM_PORTS-1:0]                enqueue_req_i,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  enqueue_bufid_i,
  input  logic [NUM_PORTS-1:0][LENGTH_W-1:0]  enqueue_length_i,
  input  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask_i,
  output logic [NUM_PORTS-1:0]                enqueue_gnt_o,

  // dequeue (NUM_PORTS consumers)
  input  logic [NUM_PORTS-1:0]               dequeue_req_i,
  output logic [NUM_PORTS-1:0]               dequeue_valid_o,
  output logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid_o,
  output logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length_o,

  // release (NUM_PORTS requesters)
  input  logic [NUM_PORTS-1:0]               release_req_i,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid_i,
  output logic [NUM_PORTS-1:0]               release_gnt_o,

  // link state (from the CPU-maintained link register, already in this clock
  // domain): enqueue destinations are masked with link_up_i, and a one-cycle
  // pulse on flush_req_i[p] drains port p's queue, releasing each buffer's
  // reference (a buffer whose count reaches 0 returns to the free list)
  input  logic [NUM_PORTS-1:0]               link_up_i,
  input  logic [NUM_PORTS-1:0]               flush_req_i,
  output logic                               flush_busy_o
);

  logic                 setref_req, setref_gnt;
  logic [BUF_ID_W-1:0]  setref_bufid;
  logic [REFCNT_W-1:0]  setref_count;

  logic                 flush_rel_req, flush_rel_gnt;
  logic [BUF_ID_W-1:0]  flush_rel_bufid;

  logic                 direct_free_req, direct_free_gnt;
  logic [BUF_ID_W-1:0]  direct_free_bufid;

  free_list_mgr u_free_list_mgr (
    .clk                  (clk),
    .rst_n                (rst_n),
    .alloc_req_i          (alloc_req_i),
    .alloc_gnt_o          (alloc_gnt_o),
    .alloc_bufid_o        (alloc_bufid_o),
    .release_req_i        (release_req_i),
    .release_bufid_i      (release_bufid_i),
    .release_gnt_o        (release_gnt_o),
    .flush_release_req_i  (flush_rel_req),
    .flush_release_bufid_i(flush_rel_bufid),
    .flush_release_gnt_o  (flush_rel_gnt),
    .setref_req_i         (setref_req),
    .setref_bufid_i       (setref_bufid),
    .setref_count_i       (setref_count),
    .setref_gnt_o         (setref_gnt),
    .direct_free_req_i    (direct_free_req),
    .direct_free_bufid_i  (direct_free_bufid),
    .direct_free_gnt_o    (direct_free_gnt)
  );

  queue_mgr u_queue_mgr (
    .clk                  (clk),
    .rst_n                (rst_n),
    .enqueue_req_i        (enqueue_req_i),
    .enqueue_bufid_i      (enqueue_bufid_i),
    .enqueue_length_i     (enqueue_length_i),
    .enqueue_destmask_i   (enqueue_destmask_i),
    .enqueue_gnt_o        (enqueue_gnt_o),
    .dequeue_req_i        (dequeue_req_i),
    .dequeue_valid_o      (dequeue_valid_o),
    .dequeue_bufid_o      (dequeue_bufid_o),
    .dequeue_length_o     (dequeue_length_o),
    .link_up_i            (link_up_i),
    .flush_req_i          (flush_req_i),
    .flush_busy_o         (flush_busy_o),
    .flush_rel_req_o      (flush_rel_req),
    .flush_rel_bufid_o    (flush_rel_bufid),
    .flush_rel_gnt_i      (flush_rel_gnt),
    .setref_req_o         (setref_req),
    .setref_bufid_o       (setref_bufid),
    .setref_count_o       (setref_count),
    .setref_gnt_i         (setref_gnt),
    .direct_free_req_o    (direct_free_req),
    .direct_free_bufid_o  (direct_free_bufid),
    .direct_free_gnt_i    (direct_free_gnt)
  );

endmodule
