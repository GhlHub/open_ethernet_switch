// ingress_top.sv
//
// Wires the 5 physical ingress front-ends, the shared AXI4 write engine,
// and buf_mgr_core together. Exposes: the AXI4 write master (to PS DDR),
// 5x AXI4-Stream RX + forwarding-decision inputs (from the MACs / a
// future MAC table lookup), and buf_mgr_core's full port-6 dequeue/
// release interface plus the CPU port's (index 5) alloc/enqueue -- those
// aren't driven by anything in this module, they're passed through for
// the egress path and CPU interface to connect to.

module ingress_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream RX from the 5 MACs (16-bit, 62.5 MHz)
  input  logic [NUM_PHYS_PORTS-1:0][15:0] s_axis_tdata,
  input  logic [NUM_PHYS_PORTS-1:0][1:0]  s_axis_tkeep,
  input  logic [NUM_PHYS_PORTS-1:0]       s_axis_tvalid,
  input  logic [NUM_PHYS_PORTS-1:0]       s_axis_tlast,
  input  logic [NUM_PHYS_PORTS-1:0]       s_axis_tuser,
  output logic [NUM_PHYS_PORTS-1:0]       s_axis_tready,

  // forwarding decision per physical port (placeholder until the MAC
  // table lookup is wired in)
  input  logic [NUM_PHYS_PORTS-1:0][NUM_PORTS-1:0] dest_mask_i,
  input  logic [NUM_PHYS_PORTS-1:0]                 dest_mask_valid_i,

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
  output logic                  m_axi_bready,

  // buf_mgr_core dequeue (all 6 ports) + release (all 6 ports) + CPU
  // (port 5) alloc/enqueue -- pass-through for the egress path / CPU
  // interface to drive
  input  logic [NUM_PORTS-1:0]               dequeue_req_i_passthru,
  output logic [NUM_PORTS-1:0]               dequeue_valid_o_passthru,
  output logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid_o_passthru,
  output logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length_o_passthru,
  // Ingress-port tag for whichever buffer this dequeue just handed out (see
  // buf_mgr_pkg's enqueue_meta_i/queue_mgr.sv's meta_mem); only the CPU port
  // (index 5) is expected to have a consumer read this.
  output logic [NUM_PORTS-1:0][PORT_ID_W-1:0] dequeue_meta_o_passthru,
  input  logic [NUM_PORTS-1:0]               release_req_i_passthru,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid_i_passthru,
  output logic [NUM_PORTS-1:0]               release_gnt_o_passthru,

  // link state / link-down flush (see queue_mgr.sv)
  input  logic [NUM_PORTS-1:0]               link_up_i,
  input  logic [NUM_PORTS-1:0]               flush_req_i,
  output logic                               flush_busy_o,

  // CPU port (index 5) alloc/enqueue -- driven BY the (not yet built) CPU
  // interface module, passed through to buf_mgr_core here
  input  logic                cpu_alloc_req_i,
  output logic                cpu_alloc_gnt_o,
  output logic [BUF_ID_W-1:0] cpu_alloc_bufid_o,
  input  logic                      cpu_enqueue_req_i,
  input  logic [BUF_ID_W-1:0]       cpu_enqueue_bufid_i,
  input  logic [LENGTH_W-1:0]       cpu_enqueue_length_i,
  input  logic [NUM_PORTS-1:0]      cpu_enqueue_destmask_i,
  output logic                      cpu_enqueue_gnt_o
);

  genvar gi;

  // ---- buf_mgr_core ----
  logic [NUM_PORTS-1:0]               alloc_req, alloc_gnt;
  logic [BUF_ID_W-1:0]                alloc_bufid;
  logic [NUM_PORTS-1:0]                enqueue_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  enqueue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0]  enqueue_length;
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask;
  // Ingress-port tag: for the 5 physical ports this is simply their own
  // fixed PORT_ID (known at elaboration time, tied below); the CPU port's
  // own slot is never read back (nothing dequeues port 5's queue at port
  // 5), so it's tied to a fixed placeholder value too.
  logic [NUM_PORTS-1:0][PORT_ID_W-1:0] enqueue_meta;
  logic [NUM_PORTS-1:0]                enqueue_gnt;

  buf_mgr_core u_buf_mgr (
    .clk                (clk),
    .rst_n              (rst_n),
    .alloc_req_i        (alloc_req),
    .alloc_gnt_o        (alloc_gnt),
    .alloc_bufid_o      (alloc_bufid),
    .enqueue_req_i      (enqueue_req),
    .enqueue_bufid_i    (enqueue_bufid),
    .enqueue_length_i   (enqueue_length),
    .enqueue_destmask_i (enqueue_destmask),
    .enqueue_meta_i     (enqueue_meta),
    .enqueue_gnt_o      (enqueue_gnt),
    .dequeue_req_i      (dequeue_req_i_passthru),
    .dequeue_valid_o    (dequeue_valid_o_passthru),
    .dequeue_bufid_o    (dequeue_bufid_o_passthru),
    .dequeue_length_o   (dequeue_length_o_passthru),
    .dequeue_meta_o     (dequeue_meta_o_passthru),
    .release_req_i      (release_req_i_passthru),
    .release_bufid_i    (release_bufid_i_passthru),
    .release_gnt_o      (release_gnt_o_passthru),
    .link_up_i          (link_up_i),
    .flush_req_i        (flush_req_i),
    .flush_busy_o       (flush_busy_o)
  );

  // CPU (port 5) alloc/enqueue: driven by the external cpu_* signals,
  // fed into buf_mgr_core's port-5 slot. alloc_gnt/alloc_bufid/
  // enqueue_gnt are buf_mgr_core outputs (driven by the instance above)
  // -- read from them here, don't drive them.
  assign alloc_req[5]        = cpu_alloc_req_i;
  assign cpu_alloc_gnt_o     = alloc_gnt[5];
  assign cpu_alloc_bufid_o   = alloc_bufid;

  assign enqueue_req[5]      = cpu_enqueue_req_i;
  assign enqueue_bufid[5]    = cpu_enqueue_bufid_i;
  assign enqueue_length[5]   = cpu_enqueue_length_i;
  assign enqueue_destmask[5] = cpu_enqueue_destmask_i;
  assign enqueue_meta[5]     = PORT_ID_W'(5); // never read back; see note above
  assign cpu_enqueue_gnt_o   = enqueue_gnt[5];

  // ---- 5 physical ingress front-ends + shared write engine ----
  logic [NUM_PHYS_PORTS-1:0]                 frame_ready;
  logic [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0]   frame_bufid;
  logic [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0]   frame_length;
  logic [NUM_PHYS_PORTS-1:0]                 frame_gnt;
  logic [NUM_PHYS_PORTS-1:0]                 frame_rd_en;
  logic [BEAT_IDX_W-1:0]                     frame_rd_addr;
  logic [NUM_PHYS_PORTS-1:0][AXI_DATA_W-1:0] frame_rd_data;
  logic [NUM_PHYS_PORTS-1:0]                 frame_dma_done;

  generate
    for (gi = 0; gi < NUM_PHYS_PORTS; gi++) begin : g_ingress_ports
      assign enqueue_meta[gi] = PORT_ID_W'(gi);
      ingress_port_wr #(.PORT_ID(gi)) u_port (
        .clk                 (clk),
        .rst_n               (rst_n),
        .s_axis_tdata        (s_axis_tdata[gi]),
        .s_axis_tkeep        (s_axis_tkeep[gi]),
        .s_axis_tvalid       (s_axis_tvalid[gi]),
        .s_axis_tlast        (s_axis_tlast[gi]),
        .s_axis_tuser        (s_axis_tuser[gi]),
        .s_axis_tready       (s_axis_tready[gi]),
        .dest_mask_i         (dest_mask_i[gi]),
        .dest_mask_valid_i   (dest_mask_valid_i[gi]),
        .alloc_req_o         (alloc_req[gi]),
        .alloc_gnt_i         (alloc_gnt[gi]),
        .alloc_bufid_i       (alloc_bufid),
        .enqueue_req_o       (enqueue_req[gi]),
        .enqueue_bufid_o     (enqueue_bufid[gi]),
        .enqueue_length_o    (enqueue_length[gi]),
        .enqueue_destmask_o  (enqueue_destmask[gi]),
        .enqueue_gnt_i       (enqueue_gnt[gi]),
        .frame_ready_o       (frame_ready[gi]),
        .frame_bufid_o       (frame_bufid[gi]),
        .frame_length_o      (frame_length[gi]),
        .frame_gnt_i         (frame_gnt[gi]),
        .frame_rd_en_i       (frame_rd_en[gi]),
        .frame_rd_addr_i     (frame_rd_addr),
        .frame_rd_data_o     (frame_rd_data[gi]),
        .frame_dma_done_i    (frame_dma_done[gi])
      );
    end
  endgenerate

  ingress_dma_wr u_dma_wr (
    .clk              (clk),
    .rst_n            (rst_n),
    .frame_ready_i    (frame_ready),
    .frame_bufid_i    (frame_bufid),
    .frame_length_i   (frame_length),
    .frame_gnt_o      (frame_gnt),
    .frame_rd_en_o    (frame_rd_en),
    .frame_rd_addr_o  (frame_rd_addr),
    .frame_rd_data_i  (frame_rd_data),
    .frame_dma_done_o (frame_dma_done),
    .m_axi_awid       (m_axi_awid),
    .m_axi_awaddr     (m_axi_awaddr),
    .m_axi_awlen      (m_axi_awlen),
    .m_axi_awsize     (m_axi_awsize),
    .m_axi_awburst    (m_axi_awburst),
    .m_axi_awvalid    (m_axi_awvalid),
    .m_axi_awready    (m_axi_awready),
    .m_axi_wdata      (m_axi_wdata),
    .m_axi_wstrb      (m_axi_wstrb),
    .m_axi_wlast      (m_axi_wlast),
    .m_axi_wvalid     (m_axi_wvalid),
    .m_axi_wready     (m_axi_wready),
    .m_axi_bid        (m_axi_bid),
    .m_axi_bresp      (m_axi_bresp),
    .m_axi_bvalid     (m_axi_bvalid),
    .m_axi_bready     (m_axi_bready)
  );

endmodule
