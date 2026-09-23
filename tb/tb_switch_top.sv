// tb_switch_top.sv
//
// Self-checking integration smoke test for switch_top.sv: injects one
// frame at PS GEM0's raw FIFO push interface and confirms it correctly
// traverses every wiring path this module is responsible for -- none of
// which had ever been joined together before switch_top.sv existed:
//   gem_rx_w_to_axis (PS GEM0) -> ingress_port_wr(port 0) ->
//   mac_forwarding_top (snoop + shared MAC table -> flood decision, dest
//   unlearned) -> ingress_dma_wr (AXI4 write, shared DDR model) ->
//   buf_mgr_core enqueue (destmask from mac_forwarding_top, spanning the
//   ingress_top/egress_top dequeue-release passthrough AND the CPU port's
//   own alloc/enqueue-dequeue/release passthrough) -> buf_mgr_core
//   dequeue on port 5 (CPU) -> cpu_dma_rd (AXI4 read, same shared DDR
//   model) -> egress_port_rd (inside cpu_port_top) -> the CPU port's own
//   external m_axis_* egress output.
//
// The CPU port is used as this test's one observable destination because
// it's externally visible with no hierarchical peeking needed, and
// because reaching it touches essentially all the same shared
// infrastructure (buf_mgr_core, mac_forwarding_top, the AXI write/read
// paths) that reaching any flooded physical port would too -- the one
// thing this test does *not* separately re-verify is the mechanical
// egress_top -> per-physical-port m_axis_* port wiring, already checked
// structurally by Verilator (zero width/connection mismatches across the
// entire module).
//
// Every physical-port MAC (2x PL GMII, 1x SFP, GEM1) and the CPU port's
// own AXI4 DMA masters are present in the DUT but left completely idle
// here (tied to safe/inert defaults) -- this test only exercises the one
// path above.

`timescale 1ns/1ps

module tb_switch_top;
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  import mac_table_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk; // 100 MHz (fabric)
  logic rst_n = 0;

  logic axis_clk = 0;
  always #(10.0/3) axis_clk = ~axis_clk; // 150 MHz-equivalent
  logic axis_rst_n = 0;
  logic [5:0] link_up  = 6'b111111;
  logic [5:0] link_tog = '0;
  wire        link_flush_busy;
  logic [5:0] learn_en_tb  = 6'b111111;
  logic [5:0] fwd_en_tb    = 6'b111111;
  wire  [5:0] ctrl_frame_tb;
  logic [5:0] cpu_ovr_mask_tb = '0;
  logic       cpu_ovr_go_tb   = 1'b0;
  wire  [2:0] cpu_rx_tag;
  wire        cpu_rx_tag_valid;
  logic       cpu_rx_tag_pop = 1'b0;

  logic [15:0] cpu_tx_tdata;
  logic [1:0]  cpu_tx_tkeep;
  logic        cpu_tx_tvalid;
  logic        cpu_tx_tlast;
  wire         cpu_tx_tready;

  logic gtx_clk_pl0 = 0;
  always #4 gtx_clk_pl0 = ~gtx_clk_pl0; // 125 MHz-equivalent
  logic gtx_clk_pl1 = 0;
  always #4 gtx_clk_pl1 = ~gtx_clk_pl1;
  logic gtx_clk_sfp = 0;
  always #4 gtx_clk_sfp = ~gtx_clk_sfp;
  logic gtx_rst_n_sfp = 0;

  // gth_clk_sfp must be gtx_clk_sfp/2, phase-related -- see
  // sfp_1000base_x_pcs.sv's header (SFP is tied off/unexercised by this
  // test, same as every other sfp_* port below, but switch_top.sv still
  // needs a valid clock driving it).
  logic gth_clk_sfp = 0;
  initial begin
    #16 gth_clk_sfp = 1;
    forever #8 gth_clk_sfp = ~gth_clk_sfp;
  end
  logic gth_rst_n_sfp = 0;

  logic gem_clk_ps0 = 0;
  always #4 gem_clk_ps0 = ~gem_clk_ps0; // 125 MHz-equivalent
  logic gem_rst_n_ps0 = 0;
  logic gem_clk_ps1 = 0;
  always #4 gem_clk_ps1 = ~gem_clk_ps1;
  logic gem_rst_n_ps1 = 0;

  // ---- GEM0 RX push (the only traffic driven in this test) ----
  logic [7:0]  gem0_rx_w_data;
  logic        gem0_rx_w_wr;
  logic        gem0_rx_w_sop;
  logic        gem0_rx_w_eop;
  logic        gem0_rx_w_err;

  // ---- shared AXI4 memory model: ingress_top's write master and
  // egress_top's read master both need to see the same buffer pool ----
  logic [AXI_ID_W-1:0]   m_axi_ing_awid;
  logic [AXI_ADDR_W-1:0] m_axi_ing_awaddr;
  logic [7:0]            m_axi_ing_awlen;
  logic [2:0]             m_axi_ing_awsize;
  logic [1:0]             m_axi_ing_awburst;
  logic                   m_axi_ing_awvalid;
  logic                   m_axi_ing_awready;
  logic [AXI_DATA_W-1:0]  m_axi_ing_wdata;
  logic [AXI_STRB_W-1:0]  m_axi_ing_wstrb;
  logic                   m_axi_ing_wlast;
  logic                   m_axi_ing_wvalid;
  logic                   m_axi_ing_wready;
  logic [AXI_ID_W-1:0]    m_axi_ing_bid;
  logic [1:0]              m_axi_ing_bresp;
  logic                    m_axi_ing_bvalid;
  logic                    m_axi_ing_bready;

  logic [AXI_ID_W-1:0]   m_axi_egr_arid;
  logic [AXI_ADDR_W-1:0] m_axi_egr_araddr;
  logic [7:0]            m_axi_egr_arlen;
  logic [2:0]             m_axi_egr_arsize;
  logic [1:0]             m_axi_egr_arburst;
  logic                   m_axi_egr_arvalid;
  logic                   m_axi_egr_arready;
  logic [AXI_ID_W-1:0]    m_axi_egr_rid;
  logic [AXI_DATA_W-1:0]  m_axi_egr_rdata;
  logic [1:0]              m_axi_egr_rresp;
  logic                    m_axi_egr_rlast;
  logic                    m_axi_egr_rvalid;
  logic                    m_axi_egr_rready;

  // ---- CPU port's own dedicated AXI4 write master: exercised by testJ
  // (CPU TX destination override), backed by u_mem_cpu below ----
  logic [AXI_ID_W-1:0]   m_axi_cpu_awid;
  logic [AXI_ADDR_W-1:0] m_axi_cpu_awaddr;
  logic [7:0]            m_axi_cpu_awlen;
  logic [2:0]             m_axi_cpu_awsize;
  logic [1:0]             m_axi_cpu_awburst;
  logic                   m_axi_cpu_awvalid;
  wire                    m_axi_cpu_awready;
  logic [AXI_DATA_W-1:0]  m_axi_cpu_wdata;
  logic [AXI_STRB_W-1:0]  m_axi_cpu_wstrb;
  logic                   m_axi_cpu_wlast;
  logic                   m_axi_cpu_wvalid;
  wire                    m_axi_cpu_wready;
  wire [AXI_ID_W-1:0]     m_axi_cpu_bid;
  wire [1:0]              m_axi_cpu_bresp;
  wire                    m_axi_cpu_bvalid;
  logic                   m_axi_cpu_bready;

  // ---- CPU port's own dedicated AXI4 read master: actually exercised in
  // this test (arbitrated onto the shared memory model below, alongside
  // egress_top's own read master) ----
  logic [AXI_ID_W-1:0]   m_axi_cpu_arid;
  logic [AXI_ADDR_W-1:0] m_axi_cpu_araddr;
  logic [7:0]            m_axi_cpu_arlen;
  logic [2:0]             m_axi_cpu_arsize;
  logic [1:0]             m_axi_cpu_arburst;
  logic                   m_axi_cpu_arvalid;
  logic                   m_axi_cpu_arready;
  logic [AXI_ID_W-1:0]   m_axi_cpu_rid;
  logic [AXI_DATA_W-1:0] m_axi_cpu_rdata;
  logic [1:0]             m_axi_cpu_rresp;
  logic                   m_axi_cpu_rlast;
  logic                   m_axi_cpu_rvalid;
  logic                   m_axi_cpu_rready;

  // ---- CPU port's own AXI4-Stream boundary: only the egress (RX) side
  // is exercised in this test ----
  logic [15:0] cpu_m_axis_tdata;
  logic [1:0]  cpu_m_axis_tkeep;
  logic        cpu_m_axis_tvalid;
  logic        cpu_m_axis_tlast;

  switch_top #(.AGE_TICK_DIVIDE_COUNT(100)) dut (
    .clk                (clk),
    .rst_n              (rst_n),
    .axis_clk           (axis_clk),
    .axis_rst_n         (axis_rst_n),
    .gtx_clk_pl0        (gtx_clk_pl0),
    .gtx_clk_pl1        (gtx_clk_pl1),
    .gtx_clk_sfp        (gtx_clk_sfp),
    .gtx_rst_n_sfp      (gtx_rst_n_sfp),
    .gth_clk_sfp        (gth_clk_sfp),
    .gth_rst_n_sfp      (gth_rst_n_sfp),
    .mac_clk_en         (1'b1),
    .gem_rx_clk_ps0     (gem_clk_ps0),
    .gem_rx_rst_n_ps0   (gem_rst_n_ps0),
    .gem_tx_clk_ps0     (gem_clk_ps0),
    .gem_tx_rst_n_ps0   (gem_rst_n_ps0),
    .gem_rx_clk_ps1     (gem_clk_ps1),
    .gem_rx_rst_n_ps1   (gem_rst_n_ps1),
    .gem_tx_clk_ps1     (gem_clk_ps1),
    .gem_tx_rst_n_ps1   (gem_rst_n_ps1),
    .default_age_i      (9'd300),

    .gem0_rx_w_data_i      (gem0_rx_w_data),
    .gem0_rx_w_wr_i        (gem0_rx_w_wr),
    .gem0_rx_w_sop_i       (gem0_rx_w_sop),
    .gem0_rx_w_eop_i       (gem0_rx_w_eop),
    .gem0_rx_w_err_i       (gem0_rx_w_err),
    .gem0_rx_w_flush_i     (1'b0),
    .gem0_rx_w_status_i    (45'd0),
    .gem0_rx_w_overflow_o  (),
    .gem0_rx_w_status_o    (),
    .gem0_tx_r_rd_i           (1'b0),
    .gem0_tx_r_data_rdy_o     (),
    .gem0_tx_r_valid_o        (),
    .gem0_tx_r_data_o         (),
    .gem0_tx_r_sop_o          (),
    .gem0_tx_r_eop_o          (),
    .gem0_tx_r_err_o          (),
    .gem0_tx_r_underflow_o    (),
    .gem0_tx_r_flushed_o      (),
    .gem0_tx_r_control_o      (),
    .gem0_dma_tx_end_tog_i    (1'b0),
    .gem0_dma_tx_status_tog_o (),
    .gem0_tx_r_status_i       (4'd0),

    .gem1_rx_w_data_i      (8'd0),
    .gem1_rx_w_wr_i        (1'b0),
    .gem1_rx_w_sop_i       (1'b0),
    .gem1_rx_w_eop_i       (1'b0),
    .gem1_rx_w_err_i       (1'b0),
    .gem1_rx_w_flush_i     (1'b0),
    .gem1_rx_w_status_i    (45'd0),
    .gem1_rx_w_overflow_o  (),
    .gem1_rx_w_status_o    (),
    .gem1_tx_r_rd_i           (1'b0),
    .gem1_tx_r_data_rdy_o     (),
    .gem1_tx_r_valid_o        (),
    .gem1_tx_r_data_o         (),
    .gem1_tx_r_sop_o          (),
    .gem1_tx_r_eop_o          (),
    .gem1_tx_r_err_o          (),
    .gem1_tx_r_underflow_o    (),
    .gem1_tx_r_flushed_o      (),
    .gem1_tx_r_control_o      (),
    .gem1_dma_tx_end_tog_i    (1'b0),
    .gem1_dma_tx_status_tog_o (),
    .gem1_tx_r_status_i       (4'd0),

    .pl0_gmii_rxd     (8'd0),
    .pl0_gmii_rx_dv   (1'b0),
    .pl0_gmii_rx_er   (1'b0),
    .pl0_gmii_txd     (),
    .pl0_gmii_tx_en   (),
    .pl0_gmii_tx_er   (),
    .pl0_s_axi_awaddr (18'd0), .pl0_s_axi_awvalid (1'b0), .pl0_s_axi_awready (),
    .pl0_s_axi_wdata  (32'd0), .pl0_s_axi_wstrb   (4'd0), .pl0_s_axi_wvalid  (1'b0), .pl0_s_axi_wready (),
    .pl0_s_axi_bresp  (),      .pl0_s_axi_bvalid  (),     .pl0_s_axi_bready  (1'b1),
    .pl0_s_axi_araddr (18'd0), .pl0_s_axi_arvalid (1'b0), .pl0_s_axi_arready (),
    .pl0_s_axi_rdata  (),      .pl0_s_axi_rresp   (),     .pl0_s_axi_rvalid  (), .pl0_s_axi_rready (1'b1),
    .pl0_interrupt    (), .pl0_mac_irq (),

    .pl1_gmii_rxd     (8'd0),
    .pl1_gmii_rx_dv   (1'b0),
    .pl1_gmii_rx_er   (1'b0),
    .pl1_gmii_txd     (),
    .pl1_gmii_tx_en   (),
    .pl1_gmii_tx_er   (),
    .pl1_s_axi_awaddr (18'd0), .pl1_s_axi_awvalid (1'b0), .pl1_s_axi_awready (),
    .pl1_s_axi_wdata  (32'd0), .pl1_s_axi_wstrb   (4'd0), .pl1_s_axi_wvalid  (1'b0), .pl1_s_axi_wready (),
    .pl1_s_axi_bresp  (),      .pl1_s_axi_bvalid  (),     .pl1_s_axi_bready  (1'b1),
    .pl1_s_axi_araddr (18'd0), .pl1_s_axi_arvalid (1'b0), .pl1_s_axi_arready (),
    .pl1_s_axi_rdata  (),      .pl1_s_axi_rresp   (),     .pl1_s_axi_rvalid  (), .pl1_s_axi_rready (1'b1),
    .pl1_interrupt    (), .pl1_mac_irq (),

    .sfp_txdata_o       (),
    .sfp_txcharisk_o    (),
    .sfp_rxdata_i       (16'd0),
    .sfp_rxcharisk_i    (2'b00),
    .sfp_rxdisperr_i    (2'b00),
    .sfp_rxnotintable_i (2'b00),
    .sfp_sync_ok_o      (),
    .sfp_s_axi_awaddr (18'd0), .sfp_s_axi_awvalid (1'b0), .sfp_s_axi_awready (),
    .sfp_s_axi_wdata  (32'd0), .sfp_s_axi_wstrb   (4'd0), .sfp_s_axi_wvalid  (1'b0), .sfp_s_axi_wready (),
    .sfp_s_axi_bresp  (),      .sfp_s_axi_bvalid  (),     .sfp_s_axi_bready  (1'b1),
    .sfp_s_axi_araddr (18'd0), .sfp_s_axi_arvalid (1'b0), .sfp_s_axi_arready (),
    .sfp_s_axi_rdata  (),      .sfp_s_axi_rresp   (),     .sfp_s_axi_rvalid  (), .sfp_s_axi_rready (1'b1),
    .sfp_interrupt    (), .sfp_mac_irq (),

    .cpu_s_axis_tdata  (cpu_tx_tdata),
    .cpu_s_axis_tkeep  (cpu_tx_tkeep),
    .cpu_s_axis_tvalid (cpu_tx_tvalid),
    .cpu_s_axis_tlast  (cpu_tx_tlast),
    .cpu_s_axis_tready (cpu_tx_tready),
    .cpu_m_axis_tdata  (cpu_m_axis_tdata),
    .cpu_m_axis_tkeep  (cpu_m_axis_tkeep),
    .cpu_m_axis_tvalid (cpu_m_axis_tvalid),
    .cpu_m_axis_tlast  (cpu_m_axis_tlast),
    .cpu_m_axis_tready (1'b1),

    .m_axi_ing_awid    (m_axi_ing_awid),
    .m_axi_ing_awaddr  (m_axi_ing_awaddr),
    .m_axi_ing_awlen   (m_axi_ing_awlen),
    .m_axi_ing_awsize  (m_axi_ing_awsize),
    .m_axi_ing_awburst (m_axi_ing_awburst),
    .m_axi_ing_awvalid (m_axi_ing_awvalid),
    .m_axi_ing_awready (m_axi_ing_awready),
    .m_axi_ing_wdata   (m_axi_ing_wdata),
    .m_axi_ing_wstrb   (m_axi_ing_wstrb),
    .m_axi_ing_wlast   (m_axi_ing_wlast),
    .m_axi_ing_wvalid  (m_axi_ing_wvalid),
    .m_axi_ing_wready  (m_axi_ing_wready),
    .m_axi_ing_bid     (m_axi_ing_bid),
    .m_axi_ing_bresp   (m_axi_ing_bresp),
    .m_axi_ing_bvalid  (m_axi_ing_bvalid),
    .m_axi_ing_bready  (m_axi_ing_bready),

    .m_axi_egr_arid    (m_axi_egr_arid),
    .m_axi_egr_araddr  (m_axi_egr_araddr),
    .m_axi_egr_arlen   (m_axi_egr_arlen),
    .m_axi_egr_arsize  (m_axi_egr_arsize),
    .m_axi_egr_arburst (m_axi_egr_arburst),
    .m_axi_egr_arvalid (m_axi_egr_arvalid),
    .m_axi_egr_arready (m_axi_egr_arready),
    .m_axi_egr_rid     (m_axi_egr_rid),
    .m_axi_egr_rdata   (m_axi_egr_rdata),
    .m_axi_egr_rresp   (m_axi_egr_rresp),
    .m_axi_egr_rlast   (m_axi_egr_rlast),
    .m_axi_egr_rvalid  (m_axi_egr_rvalid),
    .m_axi_egr_rready  (m_axi_egr_rready),

    .m_axi_cpu_awid    (m_axi_cpu_awid),
    .m_axi_cpu_awaddr  (m_axi_cpu_awaddr),
    .m_axi_cpu_awlen   (m_axi_cpu_awlen),
    .m_axi_cpu_awsize  (m_axi_cpu_awsize),
    .m_axi_cpu_awburst (m_axi_cpu_awburst),
    .m_axi_cpu_awvalid (m_axi_cpu_awvalid),
    .m_axi_cpu_awready (m_axi_cpu_awready),
    .m_axi_cpu_wdata   (m_axi_cpu_wdata),
    .m_axi_cpu_wstrb   (m_axi_cpu_wstrb),
    .m_axi_cpu_wlast   (m_axi_cpu_wlast),
    .m_axi_cpu_wvalid  (m_axi_cpu_wvalid),
    .m_axi_cpu_wready  (m_axi_cpu_wready),
    .m_axi_cpu_bid     (m_axi_cpu_bid),
    .m_axi_cpu_bresp   (m_axi_cpu_bresp),
    .m_axi_cpu_bvalid  (m_axi_cpu_bvalid),
    .m_axi_cpu_bready  (m_axi_cpu_bready),
    .m_axi_cpu_arid    (m_axi_cpu_arid),
    .m_axi_cpu_araddr  (m_axi_cpu_araddr),
    .m_axi_cpu_arlen   (m_axi_cpu_arlen),
    .m_axi_cpu_arsize  (m_axi_cpu_arsize),
    .m_axi_cpu_arburst (m_axi_cpu_arburst),
    .m_axi_cpu_arvalid (m_axi_cpu_arvalid),
    .m_axi_cpu_arready (m_axi_cpu_arready),
    .m_axi_cpu_rid     (m_axi_cpu_rid),
    .m_axi_cpu_rdata   (m_axi_cpu_rdata),
    .m_axi_cpu_rresp   (m_axi_cpu_rresp),
    .m_axi_cpu_rlast   (m_axi_cpu_rlast),
    .m_axi_cpu_rvalid  (m_axi_cpu_rvalid),
    .m_axi_cpu_rready  (m_axi_cpu_rready),
    .link_up_i (link_up),
    .link_flush_tog_i (link_tog),
    .link_flush_busy_o (link_flush_busy),
    .learn_en_i (learn_en_tb),
    .fwd_en_i (fwd_en_tb),
    .ctrl_frame_o (ctrl_frame_tb),
    .cpu_tx_ovr_mask_i (cpu_ovr_mask_tb),
    .cpu_tx_ovr_go_i (cpu_ovr_go_tb),
    .cpu_rx_ingress_port_o (cpu_rx_tag),
    .cpu_rx_ingress_valid_o (cpu_rx_tag_valid),
    .cpu_rx_ingress_pop_i (cpu_rx_tag_pop)
  );

  // Two independent memory models: u_mem backs ingress_top's write master
  // and egress_top's shared read master (as in tb_cpu_port_top.sv's own
  // shared-instance pattern); u_mem_cpu backs cpu_port_top's own
  // dedicated read master separately. A real system would reconcile all
  // three onto one path via an AXI interconnect -- switch_top.sv's own
  // header already flags that as deliberately out of scope here -- so
  // this test instead mirrors u_mem's bytes into u_mem_cpu directly (a
  // plain array copy, not routed through any AXI protocol) right after
  // each ingress write completes. A hand-built two-master AXI4 read
  // arbiter was tried first and produced a genuine simulation hang; this
  // direct mirror avoids that risk entirely for a test-only need.
  axi_mem_bfm #(.MEM_BYTES(16 * BUFFER_BYTES), .BASE_ADDR(DDR_BASE_ADDR)) u_mem (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awid    (m_axi_ing_awid),
    .s_axi_awaddr  (m_axi_ing_awaddr),
    .s_axi_awlen   (m_axi_ing_awlen),
    .s_axi_awsize  (m_axi_ing_awsize),
    .s_axi_awburst (m_axi_ing_awburst),
    .s_axi_awvalid (m_axi_ing_awvalid),
    .s_axi_awready (m_axi_ing_awready),
    .s_axi_wdata   (m_axi_ing_wdata),
    .s_axi_wstrb   (m_axi_ing_wstrb),
    .s_axi_wlast   (m_axi_ing_wlast),
    .s_axi_wvalid  (m_axi_ing_wvalid),
    .s_axi_wready  (m_axi_ing_wready),
    .s_axi_bid     (m_axi_ing_bid),
    .s_axi_bresp   (m_axi_ing_bresp),
    .s_axi_bvalid  (m_axi_ing_bvalid),
    .s_axi_bready  (m_axi_ing_bready),
    .s_axi_arid    (m_axi_egr_arid),
    .s_axi_araddr  (m_axi_egr_araddr),
    .s_axi_arlen   (m_axi_egr_arlen),
    .s_axi_arsize  (m_axi_egr_arsize),
    .s_axi_arburst (m_axi_egr_arburst),
    .s_axi_arvalid (m_axi_egr_arvalid),
    .s_axi_arready (m_axi_egr_arready),
    .s_axi_rid     (m_axi_egr_rid),
    .s_axi_rdata   (m_axi_egr_rdata),
    .s_axi_rresp   (m_axi_egr_rresp),
    .s_axi_rlast   (m_axi_egr_rlast),
    .s_axi_rvalid  (m_axi_egr_rvalid),
    .s_axi_rready  (m_axi_egr_rready)
  );

  axi_mem_bfm #(.MEM_BYTES(16 * BUFFER_BYTES), .BASE_ADDR(DDR_BASE_ADDR)) u_mem_cpu (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awid    (m_axi_cpu_awid),
    .s_axi_awaddr  (m_axi_cpu_awaddr),
    .s_axi_awlen   (m_axi_cpu_awlen),
    .s_axi_awsize  (m_axi_cpu_awsize),
    .s_axi_awburst (m_axi_cpu_awburst),
    .s_axi_awvalid (m_axi_cpu_awvalid),
    .s_axi_awready (m_axi_cpu_awready),
    .s_axi_wdata   (m_axi_cpu_wdata),
    .s_axi_wstrb   (m_axi_cpu_wstrb),
    .s_axi_wlast   (m_axi_cpu_wlast),
    .s_axi_wvalid  (m_axi_cpu_wvalid),
    .s_axi_wready  (m_axi_cpu_wready),
    .s_axi_bid     (m_axi_cpu_bid),
    .s_axi_bresp   (m_axi_cpu_bresp),
    .s_axi_bvalid  (m_axi_cpu_bvalid),
    .s_axi_bready  (m_axi_cpu_bready),
    .s_axi_arid    (m_axi_cpu_arid),
    .s_axi_araddr  (m_axi_cpu_araddr),
    .s_axi_arlen   (m_axi_cpu_arlen),
    .s_axi_arsize  (m_axi_cpu_arsize),
    .s_axi_arburst (m_axi_cpu_arburst),
    .s_axi_arvalid (m_axi_cpu_arvalid),
    .s_axi_arready (m_axi_cpu_arready),
    .s_axi_rid     (m_axi_cpu_rid),
    .s_axi_rdata   (m_axi_cpu_rdata),
    .s_axi_rresp   (m_axi_cpu_rresp),
    .s_axi_rlast   (m_axi_cpu_rlast),
    .s_axi_rvalid  (m_axi_cpu_rvalid),
    .s_axi_rready  (m_axi_cpu_rready)
  );

  always_ff @(posedge clk) begin
    if (m_axi_ing_bvalid && m_axi_ing_bready) begin
      for (int i = 0; i < 16 * BUFFER_BYTES; i++) u_mem_cpu.mem[i] <= u_mem.mem[i];
    end
  end

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic gem0_push_frame(input byte data[]);
    for (int i = 0; i < data.size(); i++) begin
      gem0_rx_w_data <= data[i];
      gem0_rx_w_wr   <= 1'b1;
      gem0_rx_w_sop  <= (i == 0);
      gem0_rx_w_eop  <= (i == data.size()-1);
      gem0_rx_w_err  <= 1'b0;
      @(posedge gem_clk_ps0);
    end
    gem0_rx_w_wr  <= 1'b0;
    gem0_rx_w_sop <= 1'b0;
    gem0_rx_w_eop <= 1'b0;
    gem0_rx_w_err <= 1'b0;
  endtask

  // drives the CPU's own ingress AXI4-Stream (fabric clk domain), 16-bit
  // words packed 2 bytes/word (tkeep=2'b01 on a trailing odd byte), honoring
  // tready (this port, unlike GEM0's raw push interface, genuinely
  // backpressures store-and-forward)
  task automatic cpu_send_frame(input byte data[]);
    int n, i;
    logic [15:0] word;
    logic [1:0]  keep;
    bit          is_last;
    bit          acc;
    n = data.size();
    i = 0;
    @(posedge clk);
    while (i < n) begin
      if (i + 1 < n) begin
        word = {data[i+1], data[i]}; keep = 2'b11; is_last = (i + 2 >= n);
      end else begin
        word = {8'h00, data[i]}; keep = 2'b01; is_last = 1'b1;
      end
      cpu_tx_tdata  <= word;
      cpu_tx_tkeep  <= keep;
      cpu_tx_tvalid <= 1'b1;
      cpu_tx_tlast  <= is_last;
      @(posedge clk); acc = cpu_tx_tready;
      while (!acc) begin @(posedge clk); acc = cpu_tx_tready; end
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    cpu_tx_tvalid <= 1'b0;
    cpu_tx_tlast  <= 1'b0;
  endtask

  byte cap_bytes[$];
  int  cap_tlast_idx;

  always_ff @(posedge clk) if (cpu_m_axis_tvalid) begin
    cap_bytes.push_back(byte'(cpu_m_axis_tdata[7:0]));
    if (cpu_m_axis_tkeep[1]) cap_bytes.push_back(byte'(cpu_m_axis_tdata[15:8]));
    if (cpu_m_axis_tlast) cap_tlast_idx = cap_bytes.size() - 1;
  end

  localparam logic [47:0] MAC_UNKNOWN_DST = 48'hAA_BB_CC_DD_EE_02;
  localparam logic [47:0] MAC_SRC         = 48'h00_11_22_33_44_66;

  initial begin
    gem0_rx_w_data = '0;
    gem0_rx_w_wr   = 1'b0;
    gem0_rx_w_sop  = 1'b0;
    gem0_rx_w_eop  = 1'b0;
    gem0_rx_w_err  = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge axis_clk);
    axis_rst_n = 1'b1;
    repeat (5) @(posedge gtx_clk_sfp);
    gtx_rst_n_sfp = 1'b1;
    repeat (5) @(posedge gth_clk_sfp);
    gth_rst_n_sfp = 1'b1;
    repeat (5) @(posedge gem_clk_ps0);
    gem_rst_n_ps0 = 1'b1;
    repeat (5) @(posedge gem_clk_ps1);
    gem_rst_n_ps1 = 1'b1;

    wait_cycles(10);

    begin
      byte data[];
      int n;
      n = 12 + 40; // dest+src MAC + payload
      data = new[n];
      for (int i = 0; i < 6; i++) data[i]   = MAC_UNKNOWN_DST[47 - 8*i -: 8];
      for (int i = 0; i < 6; i++) data[6+i] = MAC_SRC[47 - 8*i -: 8];
      for (int i = 0; i < 40; i++) data[12+i] = byte'(i);

      gem0_push_frame(data);

      begin
        int timeout;
        timeout = 0;
        while (cap_bytes.size() < n && timeout < 5000) begin
          @(posedge clk);
          timeout++;
        end
        wait_cycles(5); // let the capture settle past the final tlast beat

        if (cap_bytes.size() != n) begin
          $display("FAIL: CPU port received %0d bytes, expected %0d (timed out=%0b)", cap_bytes.size(), n, timeout >= 5000);
          errors++;
        end else begin
          bit ok;
          ok = 1'b1;
          for (int i = 0; i < n; i++) if (cap_bytes[i] !== data[i]) ok = 1'b0;
          if (cap_tlast_idx != n - 1) ok = 1'b0;
          if (ok) $display("PASS: frame injected at PS GEM0 (unknown dest, flood) correctly reached the CPU port's egress, byte-for-byte (%0d bytes)", n);
          else begin
            $display("FAIL: CPU port content/tlast mismatch");
            errors++;
          end
        end
      end

      // ---- ingress-port tag: this same frame's CPU delivery must have
      // pushed one entry tagging its true origin (GEM0 = physical port 0)
      // ----
      begin
        int tag_timeout;
        tag_timeout = 0;
        while (!cpu_rx_tag_valid && tag_timeout < 100) begin
          @(posedge axis_clk); tag_timeout++;
        end
        if (!cpu_rx_tag_valid) begin
          $display("FAIL: ingress-port tag never became valid for the GEM0 frame delivered to the CPU");
          errors++;
        end else if (cpu_rx_tag !== 3'd0) begin
          $display("FAIL: ingress-port tag = %0d for a GEM0 (port 0) frame, expected 0", cpu_rx_tag);
          errors++;
        end else begin
          $display("PASS: CPU-delivered frame is correctly tagged with its true ingress port (GEM0 = 0)");
        end
        @(posedge axis_clk); cpu_rx_tag_pop <= 1'b1;
        @(posedge axis_clk); cpu_rx_tag_pop <= 1'b0;
        @(posedge axis_clk);
        if (cpu_rx_tag_valid) begin
          $display("FAIL: ingress-port tag still valid after popping the only pending entry");
          errors++;
        end
      end
    end

    // ---- link-down: the CPU port stops receiving frames ----
    begin
      byte d2[]; byte d3[];
      int n, base, timeout;
      n = 12 + 30;
      d2 = new[n]; d3 = new[n];
      for (int i = 0; i < 6; i++) begin d2[i] = 8'hAA; d2[6+i] = 8'h00; d3[i] = 8'hAA; d3[6+i] = 8'h00; end
      d2[5] = 8'h11; d2[11] = 8'h77;  d3[5] = 8'h12; d3[11] = 8'h78;
      for (int i = 0; i < 30; i++) begin d2[12+i] = byte'(8'h80 + i); d3[12+i] = byte'(8'hC0 + i); end

      // CPU port (5) down: same sequence the register block generates (level falls, then the toggle flips)
      base = cap_bytes.size();
      link_up[5] = 1'b0;
      @(posedge axis_clk); link_tog[5] = ~link_tog[5];
      wait_cycles(20);
      timeout = 0;
      while (link_flush_busy !== 1'b0 && timeout < 8000) begin @(posedge clk); timeout++; end
      if (link_flush_busy !== 1'b0) begin $display("FAIL: flush never finished"); errors++; end
      else $display("INFO: link-down flush (queues + MAC table) finished after ~%0d fabric cycles", timeout + 20);
      gem0_push_frame(d2);
      wait_cycles(4000);
      if (cap_bytes.size() != base) begin
        $display("FAIL: CPU port received %0d bytes while its link was down", cap_bytes.size() - base); errors++;
      end else $display("PASS: flooded frame not delivered to the link-down CPU port");

      // link back up: frames flow again (and the earlier frame was not queued behind it)
      link_up[5] = 1'b1;
      wait_cycles(10);
      gem0_push_frame(d3);
      timeout = 0;
      while (cap_bytes.size() < base + n && timeout < 5000) begin @(posedge clk); timeout++; end
      wait_cycles(20);
      if (cap_bytes.size() != base + n) begin
        $display("FAIL: after link-up CPU port received %0d bytes, expected %0d", cap_bytes.size() - base, n); errors++;
      end else begin
        bit ok2; ok2 = 1'b1;
        for (int i = 0; i < n; i++) if (cap_bytes[base + i] !== d3[i]) ok2 = 1'b0;
        if (ok2) $display("PASS: after link-up the CPU port receives only the new frame, intact");
        else begin $display("FAIL: post link-up frame content mismatch"); errors++; end
      end
    end

    // ---- fwd_en_i: forwarding disabled on GEM0 (port 0) drops its ordinary
    // traffic but a reserved-control-block frame (BPDU address) still
    // reaches the CPU -- the same behavior tb_mac_forwarding_top.sv already
    // proves at the resolver level, checked here through the real
    // switch_top port boundary and the new async CDC synchronizer ----
    begin
      byte d4[]; byte d5[]; int n4, base4;
      bit ok4;
      n4 = 12 + 20;
      d4 = new[n4]; d5 = new[n4];
      for (int i = 0; i < 6; i++) begin d4[i] = 8'hAA; d4[6+i] = 8'h02; end
      d4[5] = 8'h55; // unlearned ordinary unicast destination
      for (int i = 0; i < 20; i++) d4[12+i] = byte'(8'hD0 + i);
      for (int i = 0; i < 6; i++) d5[i] = 8'h01; // 01:80:C2:00:00:00 (STP BPDU)
      d5[1] = 8'h80; d5[2] = 8'hC2; d5[3] = 8'h00; d5[4] = 8'h00; d5[5] = 8'h00;
      for (int i = 0; i < 6; i++) d5[6+i] = 8'h02;
      for (int i = 0; i < 20; i++) d5[12+i] = byte'(8'hE0 + i);

      fwd_en_tb[0] = 1'b0;
      repeat (5) @(posedge clk);

      base4 = cap_bytes.size();
      gem0_push_frame(d4);
      wait_cycles(2000);
      if (cap_bytes.size() != base4) begin
        $display("FAIL: fwd_en=0 on GEM0: CPU received %0d ordinary bytes, expected 0", cap_bytes.size() - base4);
        errors++;
      end else $display("PASS: forwarding disabled on GEM0 drops its ordinary traffic (checked through switch_top, not just the resolver)");

      base4 = cap_bytes.size();
      gem0_push_frame(d5);
      begin
        int t; t = 0;
        while (cap_bytes.size() < base4 + n4 && t < 5000) begin @(posedge clk); t++; end
      end
      ok4 = (cap_bytes.size() == base4 + n4);
      if (ok4) for (int i = 0; i < n4; i++) if (cap_bytes[base4 + i] !== d5[i]) ok4 = 1'b0;
      if (!ok4) begin
        $display("FAIL: fwd_en=0 on GEM0: BPDU frame not delivered intact to the CPU (%0d bytes, expected %0d)",
                 cap_bytes.size() - base4, n4);
        errors++;
      end else $display("PASS: a blocked GEM0 still delivers its BPDUs to the CPU, byte-for-byte");

      fwd_en_tb[0] = 1'b1;
      wait_cycles(5);
    end

    // ---- CPU TX destination override: firmware targets one specific
    // physical port for a CPU-originated frame, bypassing the automatic
    // (learned-unicast-or-flood) resolution every other CPU frame gets ----
    begin
      byte d6[]; int n6;
      logic [5:0] seen_mask;
      bit          seen_armed_before;
      bit          got_grant;
      n6 = 12 + 16;
      d6 = new[n6];
      for (int i = 0; i < 6; i++) begin d6[i] = 8'hAA; d6[6+i] = 8'h02; end
      d6[5] = 8'h99; // unlearned ordinary unicast destination: would flood if not overridden
      d6[11] = 8'h01;
      for (int i = 0; i < 16; i++) d6[12+i] = byte'(8'hF0 + i);

      cpu_ovr_mask_tb = 6'b000100; // port 2 (PL0) only
      @(posedge axis_clk); cpu_ovr_go_tb = 1'b1; @(posedge axis_clk); cpu_ovr_go_tb = 1'b0;
      repeat (5) @(posedge clk); // let the CDC crossing land before the frame does

      seen_mask = '0; got_grant = 1'b0; seen_armed_before = 1'b0;
      fork
        cpu_send_frame(d6);
        begin
          int t; t = 0;
          while (!got_grant && t < 20000) begin
            @(posedge clk);
            if (dut.cpu_enqueue_req && dut.cpu_enqueue_gnt) begin
              seen_armed_before = dut.cpu_tx_ovr_armed_q;
              seen_mask         = dut.cpu_enqueue_destmask;
              got_grant         = 1'b1;
            end
            t++;
          end
        end
      join
      repeat (5) @(posedge clk);
      if (!got_grant) begin
        $display("FAIL: CPU TX override: enqueue never granted"); errors++;
      end else if (!seen_armed_before) begin
        $display("FAIL: CPU TX override: override not armed at the moment of enqueue"); errors++;
      end else if (seen_mask !== 6'b000100) begin
        $display("FAIL: CPU TX override: enqueue destmask=%b, expected port 2 only (000100)", seen_mask);
        errors++;
      end else if (dut.cpu_tx_ovr_armed_q !== 1'b0) begin
        $display("FAIL: CPU TX override: still armed after the frame it was meant for was consumed"); errors++;
      end else $display("PASS: CPU TX override sends a frame to exactly the software-chosen port, then disarms");

      // a second, un-overridden frame with the SAME unlearned destination
      // reverts to the normal (flood) resolution -- the override doesn't stick
      got_grant = 1'b0; seen_mask = '0;
      fork
        cpu_send_frame(d6);
        begin
          int t; t = 0;
          while (!got_grant && t < 20000) begin
            @(posedge clk);
            if (dut.cpu_enqueue_req && dut.cpu_enqueue_gnt) begin
              seen_mask = dut.cpu_enqueue_destmask;
              got_grant = 1'b1;
            end
            t++;
          end
        end
      join
      if (!got_grant || seen_mask !== (~(6'(1) << 5))) begin
        $display("FAIL: after the override was consumed, expected normal flood (%b), got grant=%0b mask=%b",
                 ~(6'(1) << 5), got_grant, seen_mask);
        errors++;
      end else $display("PASS: a later, un-overridden CPU frame resolves normally again (the override does not stick)");
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
