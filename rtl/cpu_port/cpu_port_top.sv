// cpu_port_top.sv
//
// The switch's CPU port (buf_mgr_pkg::NUM_PORTS' index 5): makes the CPU
// port symmetric with the 5 physical ports at the buf_mgr_core/AXI4-
// Stream level -- ingress_port_wr(PORT_ID=5) and egress_port_rd(PORT_ID=5)
// are the exact same modules the physical ports use, just fed by a
// Vivado-configured Xilinx AXI DMA IP (Scatter/Gather mode) instead of a
// MAC. That AXI DMA is NOT instantiated here (vendor IP, not something to
// write/simulate as hand RTL -- same boundary-drawing as the GTHE4_CHANNEL
// transceiver primitive for the SFP port): this module's s_axis_*/m_axis_*
// are the boundary its MM2S/S2MM AXI4-Stream ports connect to. Configuring
// that IP for 16-bit stream width at the fabric's 62.5MHz clock avoids
// needing any width/CDC adapter here, unlike the GEM and PL GMII MAC
// integrations, whose external interfaces had genuinely fixed widths/rates.
//
// s_axis_* (ingress, CPU TX -> switch): the AXI DMA's MM2S channel reads
// frame bytes out of Linux's own TX socket-buffer memory via its own SG
// descriptor ring and streams them in here. ingress_port_wr allocates a
// buf_mgr_core buffer and cpu_dma_wr.sv (this port's own dedicated,
// non-arbitrated AXI4 write master -- see that file's header) DMAs the
// bytes into it, exactly as a physical port would.
//
// m_axis_* (egress, switch -> CPU RX): buf_mgr_core delivers a frame to
// the CPU port's queue (unicast-to-CPU, flooded/trapped traffic, etc.);
// egress_port_rd dequeues it, cpu_dma_rd.sv DMAs the bytes out of
// buf_mgr_core's buffer pool, and they stream out here into the AXI DMA's
// S2MM channel, which writes them into Linux's RX socket-buffer memory
// via its own SG descriptor ring.
//
// This module's own m_axi_w*/m_axi_r* ports are its dedicated AXI4 masters
// into buf_mgr_core's DDR buffer pool -- the SAME buffer-pool region the 5
// physical ports' shared ingress_dma_wr/egress_dma_rd engines also access
// (different physical AXI4 masters; reconciling them onto one path to DDR
// is an AXI interconnect/crossbar concern for whatever top-level SoC
// integration joins this module, ingress_top.sv, egress_top.sv, and the
// PS DDR ports -- not built here).
//
// alloc/enqueue/dequeue/release: wired straight through to
// ingress_top.sv's/egress_top.sv's own cpu_* passthrough ports (see both
// files' headers, which anticipated exactly this "future CPU interface
// module") -- this module's port names mirror those from its own
// perspective (e.g. ingress_top.sv's `input cpu_alloc_req_i` <->
// this module's `output cpu_alloc_req_o`).

module cpu_port_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream ingress in (CPU TX -> switch), 16-bit, 62.5 MHz
  // (<- AXI DMA MM2S)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // AXI4-Stream egress out (switch -> CPU RX), 16-bit, 62.5 MHz
  // (-> AXI DMA S2MM)
  output logic [15:0] m_axis_tdata,
  output logic [1:0]  m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  input  logic         m_axis_tready,

  // forwarding decision for CPU-originated frames (placeholder until the
  // MAC table lookup is wired in -- same pass-through convention as
  // ingress_top.sv's per-physical-port dest_mask_i/dest_mask_valid_i;
  // ingress_port_wr's S_ENQ_WAIT state blocks indefinitely on
  // dest_mask_valid_i, so this must NOT be tied off)
  input  logic [NUM_PORTS-1:0] dest_mask_i,
  input  logic                 dest_mask_valid_i,

  // buf_mgr_core alloc/enqueue (ingress side) -- to/from ingress_top.sv's
  // cpu_alloc_*/cpu_enqueue_* passthrough ports
  output logic                cpu_alloc_req_o,
  input  logic                cpu_alloc_gnt_i,
  input  logic [BUF_ID_W-1:0] cpu_alloc_bufid_i,
  output logic                     cpu_enqueue_req_o,
  output logic [BUF_ID_W-1:0]      cpu_enqueue_bufid_o,
  output logic [LENGTH_W-1:0]      cpu_enqueue_length_o,
  output logic [NUM_PORTS-1:0]     cpu_enqueue_destmask_o,
  input  logic                     cpu_enqueue_gnt_i,

  // buf_mgr_core dequeue/release (egress side) -- to/from egress_top.sv's
  // cpu_dequeue_*/cpu_release_* passthrough ports
  input  logic                cpu_dequeue_valid_i,
  input  logic [BUF_ID_W-1:0] cpu_dequeue_bufid_i,
  input  logic [LENGTH_W-1:0] cpu_dequeue_length_i,
  output logic                cpu_dequeue_req_o,
  output logic                cpu_release_req_o,
  output logic [BUF_ID_W-1:0] cpu_release_bufid_o,
  input  logic                cpu_release_gnt_i,

  // dedicated AXI4 write master -> buf_mgr_core's DDR buffer pool
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

  // dedicated AXI4 read master <- buf_mgr_core's DDR buffer pool
  output logic [AXI_ID_W-1:0]   m_axi_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,
  input  logic [AXI_ID_W-1:0]   m_axi_rid,
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  // ---- ingress (CPU TX -> switch) ----
  logic                  frame_ready;
  logic [BUF_ID_W-1:0]   frame_bufid_wr;
  logic [LENGTH_W-1:0]   frame_length_wr;
  logic                  frame_gnt_wr;
  logic                  frame_rd_en;
  logic [BEAT_IDX_W-1:0] frame_rd_addr;
  logic [AXI_DATA_W-1:0] frame_rd_data;
  logic                  frame_dma_done_wr;

  ingress_port_wr #(.PORT_ID(5)) u_ingress (
    .clk                (clk),
    .rst_n              (rst_n),
    .s_axis_tdata       (s_axis_tdata),
    .s_axis_tkeep       (s_axis_tkeep),
    .s_axis_tvalid      (s_axis_tvalid),
    .s_axis_tlast       (s_axis_tlast),
    .s_axis_tuser       (1'b0), // AXI DMA MM2S has no error signal to carry here
    .s_axis_tready      (s_axis_tready),
    .dest_mask_i        (dest_mask_i),
    .dest_mask_valid_i  (dest_mask_valid_i),
    .alloc_req_o        (cpu_alloc_req_o),
    .alloc_gnt_i        (cpu_alloc_gnt_i),
    .alloc_bufid_i      (cpu_alloc_bufid_i),
    .enqueue_req_o      (cpu_enqueue_req_o),
    .enqueue_bufid_o    (cpu_enqueue_bufid_o),
    .enqueue_length_o   (cpu_enqueue_length_o),
    .enqueue_destmask_o (cpu_enqueue_destmask_o),
    .enqueue_gnt_i      (cpu_enqueue_gnt_i),
    .frame_ready_o      (frame_ready),
    .frame_bufid_o      (frame_bufid_wr),
    .frame_length_o     (frame_length_wr),
    .frame_gnt_i        (frame_gnt_wr),
    .frame_rd_en_i      (frame_rd_en),
    .frame_rd_addr_i    (frame_rd_addr),
    .frame_rd_data_o    (frame_rd_data),
    .frame_dma_done_i   (frame_dma_done_wr)
  );

  cpu_dma_wr u_dma_wr (
    .clk              (clk),
    .rst_n            (rst_n),
    .frame_ready_i    (frame_ready),
    .frame_bufid_i    (frame_bufid_wr),
    .frame_length_i   (frame_length_wr),
    .frame_gnt_o      (frame_gnt_wr),
    .frame_rd_en_o    (frame_rd_en),
    .frame_rd_addr_o  (frame_rd_addr),
    .frame_rd_data_i  (frame_rd_data),
    .frame_dma_done_o (frame_dma_done_wr),
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

  // ---- egress (switch -> CPU RX) ----
  logic                  frame_req;
  logic [BUF_ID_W-1:0]   frame_bufid_rd;
  logic [LENGTH_W-1:0]   frame_length_rd;
  logic                  frame_gnt_rd;
  logic                  frame_wr_en;
  logic [BEAT_IDX_W-1:0] frame_wr_addr;
  logic [AXI_DATA_W-1:0] frame_wr_data;
  logic                  frame_dma_done_rd;

  egress_port_rd #(.PORT_ID(5)) u_egress (
    .clk               (clk),
    .rst_n             (rst_n),
    .m_axis_tdata      (m_axis_tdata),
    .m_axis_tkeep      (m_axis_tkeep),
    .m_axis_tvalid     (m_axis_tvalid),
    .m_axis_tlast      (m_axis_tlast),
    .m_axis_tready     (m_axis_tready),
    .dequeue_req_o     (cpu_dequeue_req_o),
    .dequeue_valid_i   (cpu_dequeue_valid_i),
    .dequeue_bufid_i   (cpu_dequeue_bufid_i),
    .dequeue_length_i  (cpu_dequeue_length_i),
    .release_req_o     (cpu_release_req_o),
    .release_bufid_o   (cpu_release_bufid_o),
    .release_gnt_i     (cpu_release_gnt_i),
    .frame_req_o       (frame_req),
    .frame_bufid_o     (frame_bufid_rd),
    .frame_length_o    (frame_length_rd),
    .frame_gnt_i       (frame_gnt_rd),
    .frame_wr_en_i     (frame_wr_en),
    .frame_wr_addr_i   (frame_wr_addr),
    .frame_wr_data_i   (frame_wr_data),
    .frame_dma_done_i  (frame_dma_done_rd)
  );

  cpu_dma_rd u_dma_rd (
    .clk              (clk),
    .rst_n            (rst_n),
    .frame_req_i      (frame_req),
    .frame_bufid_i    (frame_bufid_rd),
    .frame_length_i   (frame_length_rd),
    .frame_gnt_o      (frame_gnt_rd),
    .frame_wr_en_o    (frame_wr_en),
    .frame_wr_addr_o  (frame_wr_addr),
    .frame_wr_data_o  (frame_wr_data),
    .frame_dma_done_o (frame_dma_done_rd),
    .m_axi_arid       (m_axi_arid),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arlen      (m_axi_arlen),
    .m_axi_arsize     (m_axi_arsize),
    .m_axi_arburst    (m_axi_arburst),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_rid        (m_axi_rid),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rlast      (m_axi_rlast),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready)
  );

endmodule
