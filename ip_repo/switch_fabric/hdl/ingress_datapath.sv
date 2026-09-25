// Physical ingress pipelines and shared writer; buffer ownership belongs to switch_fabric.
module ingress_datapath
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input wire  clk,
  input wire  rst_n,
  input wire [NUM_PHYS_PORTS-1:0][15:0]  s_axis_tdata,
  input wire [NUM_PHYS_PORTS-1:0][1:0]   s_axis_tkeep,
  input wire [NUM_PHYS_PORTS-1:0]        s_axis_tvalid,
  input wire [NUM_PHYS_PORTS-1:0]        s_axis_tlast,
  input wire [NUM_PHYS_PORTS-1:0]        s_axis_tuser,
  output wire [NUM_PHYS_PORTS-1:0]        s_axis_tready,
  input wire [NUM_PHYS_PORTS-1:0][NUM_PORTS-1:0]  dest_mask_i,
  input wire [NUM_PHYS_PORTS-1:0]                  dest_mask_valid_i,
  output wire [AXI_ID_W-1:0]    m_axi_awid,
  output wire [AXI_ADDR_W-1:0]  m_axi_awaddr,
  output wire [7:0]             m_axi_awlen,
  output wire [2:0]             m_axi_awsize,
  output wire [1:0]             m_axi_awburst,
  output wire  m_axi_awvalid,
  input wire  m_axi_awready,
  output wire [AXI_DATA_W-1:0]  m_axi_wdata,
  output wire [AXI_STRB_W-1:0]  m_axi_wstrb,
  output wire  m_axi_wlast,
  output wire  m_axi_wvalid,
  input wire  m_axi_wready,
  input wire [AXI_ID_W-1:0]    m_axi_bid,
  input wire [1:0]             m_axi_bresp,
  input wire  m_axi_bvalid,
  output wire  m_axi_bready,
  output wire [NUM_PHYS_PORTS-1:0] alloc_req,
  input wire [NUM_PHYS_PORTS-1:0] alloc_gnt,
  input wire [BUF_ID_W-1:0] alloc_bufid,
  output wire [NUM_PHYS_PORTS-1:0] enqueue_req,
  output wire [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0] enqueue_bufid,
  output wire [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0] enqueue_length,
  output wire [NUM_PHYS_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask,
  input wire [NUM_PHYS_PORTS-1:0] enqueue_gnt
);
  genvar gi;
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
