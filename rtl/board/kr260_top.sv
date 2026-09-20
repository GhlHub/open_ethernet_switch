// kr260_top.sv
//
// Board top: the generated block-design wrapper (Zynq PS, AXI interconnect,
// CPU-port AXI DMA -- build/build_kr260.tcl) beside kr260_pl_top.sv (the switch
// and its PHY/transceiver interfaces), connected name-for-name. A block-design
// module reference is not usable for kr260_pl_top because it contains vendor
// IP (clock wizards, GTH), so the two are joined here instead.
//
// Mechanical glue, derived from the two modules' actual port lists:
//   - same-named ports are wired together (directions are opposite by design);
//   - the block design's AXI-Lite address buses are 32-bit; the RTL slaves
//     take 8/18 bits -- the low bits are used (the interconnect window fixes
//     the rest);
//   - m_axi_ing/m_axi_egr are write-only/read-only in the RTL but full AXI4
//     in the block design: the unused channel is tied idle;
//   - the RTL's 1-bit AXI IDs are unused (single outstanding, ID 0): B/R IDs
//     are tied to 0 and AW/AR IDs left open;
//   - AXI cache/lock/prot/qos, which the RTL does not drive, are tied to 0.

module kr260_top (
  input  wire pl0_ref_clk_25m,
  output wire [3:0] pl0_rgmii_txd,
  output wire pl0_rgmii_tx_ctl,
  output wire pl0_rgmii_txc,
  input  wire [3:0] pl0_rgmii_rxd,
  input  wire pl0_rgmii_rx_ctl,
  input  wire pl0_rgmii_rxc,
  inout  wire pl0_mdio,
  output wire pl0_mdc,
  output wire pl0_phy_reset_n,
  input  wire pl1_ref_clk_25m,
  output wire [3:0] pl1_rgmii_txd,
  output wire pl1_rgmii_tx_ctl,
  output wire pl1_rgmii_txc,
  input  wire [3:0] pl1_rgmii_rxd,
  input  wire pl1_rgmii_rx_ctl,
  input  wire pl1_rgmii_rxc,
  inout  wire pl1_mdio,
  output wire pl1_mdc,
  output wire pl1_phy_reset_n,
  input  wire sfp_refclk_p,
  input  wire sfp_refclk_n,
  output wire sfp_txp,
  output wire sfp_txn,
  input  wire sfp_rxp,
  input  wire sfp_rxn,
  input  wire sfp_los,
  input  wire sfp_mod_abs,
  input  wire sfp_tx_fault,
  output wire sfp_tx_disable,
  output wire [1:0] sfp_led,
  inout  wire sfp_iic_scl_io,
  inout  wire sfp_iic_sda_io
);

  wire link_irq;
  wire ps_rst_n;
  wire freerun_clk;
  wire fabric_clk_o;
  wire fabric_rst_n_o;
  wire [31:0] mdio0_s_axi_awaddr;
  wire mdio0_s_axi_awvalid;
  wire mdio0_s_axi_awready;
  wire [31:0] mdio0_s_axi_wdata;
  wire [3:0] mdio0_s_axi_wstrb;
  wire mdio0_s_axi_wvalid;
  wire mdio0_s_axi_wready;
  wire [1:0] mdio0_s_axi_bresp;
  wire mdio0_s_axi_bvalid;
  wire mdio0_s_axi_bready;
  wire [31:0] mdio0_s_axi_araddr;
  wire mdio0_s_axi_arvalid;
  wire mdio0_s_axi_arready;
  wire [31:0] mdio0_s_axi_rdata;
  wire [1:0] mdio0_s_axi_rresp;
  wire mdio0_s_axi_rvalid;
  wire mdio0_s_axi_rready;
  wire [31:0] mdio1_s_axi_awaddr;
  wire mdio1_s_axi_awvalid;
  wire mdio1_s_axi_awready;
  wire [31:0] mdio1_s_axi_wdata;
  wire [3:0] mdio1_s_axi_wstrb;
  wire mdio1_s_axi_wvalid;
  wire mdio1_s_axi_wready;
  wire [1:0] mdio1_s_axi_bresp;
  wire mdio1_s_axi_bvalid;
  wire mdio1_s_axi_bready;
  wire [31:0] mdio1_s_axi_araddr;
  wire mdio1_s_axi_arvalid;
  wire mdio1_s_axi_arready;
  wire [31:0] mdio1_s_axi_rdata;
  wire [1:0] mdio1_s_axi_rresp;
  wire mdio1_s_axi_rvalid;
  wire mdio1_s_axi_rready;
  wire [31:0] diag_s_axi_awaddr;
  wire diag_s_axi_awvalid;
  wire diag_s_axi_awready;
  wire [31:0] diag_s_axi_wdata;
  wire [3:0] diag_s_axi_wstrb;
  wire diag_s_axi_wvalid;
  wire diag_s_axi_wready;
  wire [1:0] diag_s_axi_bresp;
  wire diag_s_axi_bvalid;
  wire diag_s_axi_bready;
  wire [31:0] diag_s_axi_araddr;
  wire diag_s_axi_arvalid;
  wire diag_s_axi_arready;
  wire [31:0] diag_s_axi_rdata;
  wire [1:0] diag_s_axi_rresp;
  wire diag_s_axi_rvalid;
  wire diag_s_axi_rready;
  wire axis_clk;
  wire [0:0] axis_rst_n;
  wire gem0_rx_clk;
  wire gem0_tx_clk;
  wire gem1_rx_clk;
  wire gem1_tx_clk;
  wire [7:0] gem0_rx_w_data_i;
  wire gem0_rx_w_wr_i;
  wire gem0_rx_w_sop_i;
  wire gem0_rx_w_eop_i;
  wire gem0_rx_w_err_i;
  wire gem0_rx_w_flush_i;
  wire [44:0] gem0_rx_w_status_i;
  wire gem0_rx_w_overflow_o;
  wire gem0_tx_r_rd_i;
  wire gem0_tx_r_data_rdy_o;
  wire gem0_tx_r_valid_o;
  wire [7:0] gem0_tx_r_data_o;
  wire gem0_tx_r_sop_o;
  wire gem0_tx_r_eop_o;
  wire gem0_tx_r_err_o;
  wire gem0_tx_r_underflow_o;
  wire gem0_tx_r_flushed_o;
  wire gem0_tx_r_control_o;
  wire gem0_dma_tx_end_tog_i;
  wire gem0_dma_tx_status_tog_o;
  wire [3:0] gem0_tx_r_status_i;
  wire [7:0] gem1_rx_w_data_i;
  wire gem1_rx_w_wr_i;
  wire gem1_rx_w_sop_i;
  wire gem1_rx_w_eop_i;
  wire gem1_rx_w_err_i;
  wire gem1_rx_w_flush_i;
  wire [44:0] gem1_rx_w_status_i;
  wire gem1_rx_w_overflow_o;
  wire gem1_tx_r_rd_i;
  wire gem1_tx_r_data_rdy_o;
  wire gem1_tx_r_valid_o;
  wire [7:0] gem1_tx_r_data_o;
  wire gem1_tx_r_sop_o;
  wire gem1_tx_r_eop_o;
  wire gem1_tx_r_err_o;
  wire gem1_tx_r_underflow_o;
  wire gem1_tx_r_flushed_o;
  wire gem1_tx_r_control_o;
  wire gem1_dma_tx_end_tog_i;
  wire gem1_dma_tx_status_tog_o;
  wire [3:0] gem1_tx_r_status_i;
  wire [31:0] pl0_s_axi_awaddr;
  wire pl0_s_axi_awvalid;
  wire pl0_s_axi_awready;
  wire [31:0] pl0_s_axi_wdata;
  wire [3:0] pl0_s_axi_wstrb;
  wire pl0_s_axi_wvalid;
  wire pl0_s_axi_wready;
  wire [1:0] pl0_s_axi_bresp;
  wire pl0_s_axi_bvalid;
  wire pl0_s_axi_bready;
  wire [31:0] pl0_s_axi_araddr;
  wire pl0_s_axi_arvalid;
  wire pl0_s_axi_arready;
  wire [31:0] pl0_s_axi_rdata;
  wire [1:0] pl0_s_axi_rresp;
  wire pl0_s_axi_rvalid;
  wire pl0_s_axi_rready;
  wire pl0_interrupt;
  wire pl0_mac_irq;
  wire [31:0] pl1_s_axi_awaddr;
  wire pl1_s_axi_awvalid;
  wire pl1_s_axi_awready;
  wire [31:0] pl1_s_axi_wdata;
  wire [3:0] pl1_s_axi_wstrb;
  wire pl1_s_axi_wvalid;
  wire pl1_s_axi_wready;
  wire [1:0] pl1_s_axi_bresp;
  wire pl1_s_axi_bvalid;
  wire pl1_s_axi_bready;
  wire [31:0] pl1_s_axi_araddr;
  wire pl1_s_axi_arvalid;
  wire pl1_s_axi_arready;
  wire [31:0] pl1_s_axi_rdata;
  wire [1:0] pl1_s_axi_rresp;
  wire pl1_s_axi_rvalid;
  wire pl1_s_axi_rready;
  wire pl1_interrupt;
  wire pl1_mac_irq;
  wire [31:0] sfp_s_axi_awaddr;
  wire sfp_s_axi_awvalid;
  wire sfp_s_axi_awready;
  wire [31:0] sfp_s_axi_wdata;
  wire [3:0] sfp_s_axi_wstrb;
  wire sfp_s_axi_wvalid;
  wire sfp_s_axi_wready;
  wire [1:0] sfp_s_axi_bresp;
  wire sfp_s_axi_bvalid;
  wire sfp_s_axi_bready;
  wire [31:0] sfp_s_axi_araddr;
  wire sfp_s_axi_arvalid;
  wire sfp_s_axi_arready;
  wire [31:0] sfp_s_axi_rdata;
  wire [1:0] sfp_s_axi_rresp;
  wire sfp_s_axi_rvalid;
  wire sfp_s_axi_rready;
  wire sfp_interrupt;
  wire sfp_mac_irq;
  wire [15:0] cpu_s_axis_tdata;
  wire [1:0] cpu_s_axis_tkeep;
  wire cpu_s_axis_tvalid;
  wire cpu_s_axis_tlast;
  wire cpu_s_axis_tready;
  wire [15:0] cpu_m_axis_tdata;
  wire [1:0] cpu_m_axis_tkeep;
  wire cpu_m_axis_tvalid;
  wire cpu_m_axis_tlast;
  wire cpu_m_axis_tready;
  wire [31:0] m_axi_ing_awaddr;
  wire [7:0] m_axi_ing_awlen;
  wire [2:0] m_axi_ing_awsize;
  wire [1:0] m_axi_ing_awburst;
  wire m_axi_ing_awvalid;
  wire m_axi_ing_awready;
  wire [127:0] m_axi_ing_wdata;
  wire [15:0] m_axi_ing_wstrb;
  wire m_axi_ing_wlast;
  wire m_axi_ing_wvalid;
  wire m_axi_ing_wready;
  wire [1:0] m_axi_ing_bresp;
  wire m_axi_ing_bvalid;
  wire m_axi_ing_bready;
  wire [31:0] m_axi_egr_araddr;
  wire [7:0] m_axi_egr_arlen;
  wire [2:0] m_axi_egr_arsize;
  wire [1:0] m_axi_egr_arburst;
  wire m_axi_egr_arvalid;
  wire m_axi_egr_arready;
  wire [127:0] m_axi_egr_rdata;
  wire [1:0] m_axi_egr_rresp;
  wire m_axi_egr_rlast;
  wire m_axi_egr_rvalid;
  wire m_axi_egr_rready;
  wire [31:0] m_axi_cpu_awaddr;
  wire [7:0] m_axi_cpu_awlen;
  wire [2:0] m_axi_cpu_awsize;
  wire [1:0] m_axi_cpu_awburst;
  wire m_axi_cpu_awvalid;
  wire m_axi_cpu_awready;
  wire [127:0] m_axi_cpu_wdata;
  wire [15:0] m_axi_cpu_wstrb;
  wire m_axi_cpu_wlast;
  wire m_axi_cpu_wvalid;
  wire m_axi_cpu_wready;
  wire [1:0] m_axi_cpu_bresp;
  wire m_axi_cpu_bvalid;
  wire m_axi_cpu_bready;
  wire [31:0] m_axi_cpu_araddr;
  wire [7:0] m_axi_cpu_arlen;
  wire [2:0] m_axi_cpu_arsize;
  wire [1:0] m_axi_cpu_arburst;
  wire m_axi_cpu_arvalid;
  wire m_axi_cpu_arready;
  wire [127:0] m_axi_cpu_rdata;
  wire [1:0] m_axi_cpu_rresp;
  wire m_axi_cpu_rlast;
  wire m_axi_cpu_rvalid;
  wire m_axi_cpu_rready;

  system_wrapper u_bd (
    .link_irq (link_irq),
    .sfp_iic_scl_io (sfp_iic_scl_io),
    .sfp_iic_sda_io (sfp_iic_sda_io),
    .axis_clk (axis_clk),
    .axis_rst_n (axis_rst_n),
    .cpu_m_axis_tdata (cpu_m_axis_tdata),
    .cpu_m_axis_tkeep (cpu_m_axis_tkeep),
    .cpu_m_axis_tlast (cpu_m_axis_tlast),
    .cpu_m_axis_tready (cpu_m_axis_tready),
    .cpu_m_axis_tvalid (cpu_m_axis_tvalid),
    .cpu_s_axis_tdata (cpu_s_axis_tdata),
    .cpu_s_axis_tkeep (cpu_s_axis_tkeep),
    .cpu_s_axis_tlast (cpu_s_axis_tlast),
    .cpu_s_axis_tready (cpu_s_axis_tready),
    .cpu_s_axis_tvalid (cpu_s_axis_tvalid),
    .fabric_clk_o (fabric_clk_o),
    .fabric_rst_n_o (fabric_rst_n_o),
    .freerun_clk (freerun_clk),
    .gem0_dma_tx_end_tog_i (gem0_dma_tx_end_tog_i),
    .gem0_dma_tx_status_tog_o (gem0_dma_tx_status_tog_o),
    .gem0_rx_w_data_i (gem0_rx_w_data_i),
    .gem0_rx_w_eop_i (gem0_rx_w_eop_i),
    .gem0_rx_w_err_i (gem0_rx_w_err_i),
    .gem0_rx_w_flush_i (gem0_rx_w_flush_i),
    .gem0_rx_w_overflow_o (gem0_rx_w_overflow_o),
    .gem0_rx_w_sop_i (gem0_rx_w_sop_i),
    .gem0_rx_w_status_i (gem0_rx_w_status_i),
    .gem0_rx_w_wr_i (gem0_rx_w_wr_i),
    .gem0_tx_r_control_o (gem0_tx_r_control_o),
    .gem0_tx_r_data_o (gem0_tx_r_data_o),
    .gem0_tx_r_data_rdy_o (gem0_tx_r_data_rdy_o),
    .gem0_tx_r_eop_o (gem0_tx_r_eop_o),
    .gem0_tx_r_err_o (gem0_tx_r_err_o),
    .gem0_tx_r_flushed_o (gem0_tx_r_flushed_o),
    .gem0_tx_r_rd_i (gem0_tx_r_rd_i),
    .gem0_tx_r_sop_o (gem0_tx_r_sop_o),
    .gem0_tx_r_status_i (gem0_tx_r_status_i),
    .gem0_tx_r_underflow_o (gem0_tx_r_underflow_o),
    .gem0_tx_r_valid_o (gem0_tx_r_valid_o),
    .gem1_dma_tx_end_tog_i (gem1_dma_tx_end_tog_i),
    .gem1_dma_tx_status_tog_o (gem1_dma_tx_status_tog_o),
    .gem1_rx_w_data_i (gem1_rx_w_data_i),
    .gem1_rx_w_eop_i (gem1_rx_w_eop_i),
    .gem1_rx_w_err_i (gem1_rx_w_err_i),
    .gem1_rx_w_flush_i (gem1_rx_w_flush_i),
    .gem1_rx_w_overflow_o (gem1_rx_w_overflow_o),
    .gem1_rx_w_sop_i (gem1_rx_w_sop_i),
    .gem1_rx_w_status_i (gem1_rx_w_status_i),
    .gem1_rx_w_wr_i (gem1_rx_w_wr_i),
    .gem1_tx_r_control_o (gem1_tx_r_control_o),
    .gem1_tx_r_data_o (gem1_tx_r_data_o),
    .gem1_tx_r_data_rdy_o (gem1_tx_r_data_rdy_o),
    .gem1_tx_r_eop_o (gem1_tx_r_eop_o),
    .gem1_tx_r_err_o (gem1_tx_r_err_o),
    .gem1_tx_r_flushed_o (gem1_tx_r_flushed_o),
    .gem1_tx_r_rd_i (gem1_tx_r_rd_i),
    .gem1_tx_r_sop_o (gem1_tx_r_sop_o),
    .gem1_tx_r_status_i (gem1_tx_r_status_i),
    .gem1_tx_r_underflow_o (gem1_tx_r_underflow_o),
    .gem1_tx_r_valid_o (gem1_tx_r_valid_o),
    .gem0_rx_clk (gem0_rx_clk),
    .gem0_tx_clk (gem0_tx_clk),
    .gem1_rx_clk (gem1_rx_clk),
    .gem1_tx_clk (gem1_tx_clk),
    .m_axi_cpu_araddr (m_axi_cpu_araddr),
    .m_axi_cpu_arburst (m_axi_cpu_arburst),
    .m_axi_cpu_arcache ('0),
    .m_axi_cpu_arlen (m_axi_cpu_arlen),
    .m_axi_cpu_arlock ('0),
    .m_axi_cpu_arprot ('0),
    .m_axi_cpu_arqos ('0),
    .m_axi_cpu_arready (m_axi_cpu_arready),
    .m_axi_cpu_arsize (m_axi_cpu_arsize),
    .m_axi_cpu_arvalid (m_axi_cpu_arvalid),
    .m_axi_cpu_awaddr (m_axi_cpu_awaddr),
    .m_axi_cpu_awburst (m_axi_cpu_awburst),
    .m_axi_cpu_awcache ('0),
    .m_axi_cpu_awlen (m_axi_cpu_awlen),
    .m_axi_cpu_awlock ('0),
    .m_axi_cpu_awprot ('0),
    .m_axi_cpu_awqos ('0),
    .m_axi_cpu_awready (m_axi_cpu_awready),
    .m_axi_cpu_awsize (m_axi_cpu_awsize),
    .m_axi_cpu_awvalid (m_axi_cpu_awvalid),
    .m_axi_cpu_bready (m_axi_cpu_bready),
    .m_axi_cpu_bresp (m_axi_cpu_bresp),
    .m_axi_cpu_bvalid (m_axi_cpu_bvalid),
    .m_axi_cpu_rdata (m_axi_cpu_rdata),
    .m_axi_cpu_rlast (m_axi_cpu_rlast),
    .m_axi_cpu_rready (m_axi_cpu_rready),
    .m_axi_cpu_rresp (m_axi_cpu_rresp),
    .m_axi_cpu_rvalid (m_axi_cpu_rvalid),
    .m_axi_cpu_wdata (m_axi_cpu_wdata),
    .m_axi_cpu_wlast (m_axi_cpu_wlast),
    .m_axi_cpu_wready (m_axi_cpu_wready),
    .m_axi_cpu_wstrb (m_axi_cpu_wstrb),
    .m_axi_cpu_wvalid (m_axi_cpu_wvalid),
    .m_axi_egr_araddr (m_axi_egr_araddr),
    .m_axi_egr_arburst (m_axi_egr_arburst),
    .m_axi_egr_arcache ('0),
    .m_axi_egr_arlen (m_axi_egr_arlen),
    .m_axi_egr_arlock ('0),
    .m_axi_egr_arprot ('0),
    .m_axi_egr_arqos ('0),
    .m_axi_egr_arready (m_axi_egr_arready),
    .m_axi_egr_arsize (m_axi_egr_arsize),
    .m_axi_egr_arvalid (m_axi_egr_arvalid),
    .m_axi_egr_awaddr ('0),
    .m_axi_egr_awburst ('0),
    .m_axi_egr_awcache ('0),
    .m_axi_egr_awlen ('0),
    .m_axi_egr_awlock ('0),
    .m_axi_egr_awprot ('0),
    .m_axi_egr_awqos ('0),
    .m_axi_egr_awsize ('0),
    .m_axi_egr_awvalid ('0),
    .m_axi_egr_bready ('0),
    .m_axi_egr_rdata (m_axi_egr_rdata),
    .m_axi_egr_rlast (m_axi_egr_rlast),
    .m_axi_egr_rready (m_axi_egr_rready),
    .m_axi_egr_rresp (m_axi_egr_rresp),
    .m_axi_egr_rvalid (m_axi_egr_rvalid),
    .m_axi_egr_wdata ('0),
    .m_axi_egr_wlast ('0),
    .m_axi_egr_wstrb ('0),
    .m_axi_egr_wvalid ('0),
    .m_axi_ing_araddr ('0),
    .m_axi_ing_arburst ('0),
    .m_axi_ing_arcache ('0),
    .m_axi_ing_arlen ('0),
    .m_axi_ing_arlock ('0),
    .m_axi_ing_arprot ('0),
    .m_axi_ing_arqos ('0),
    .m_axi_ing_arsize ('0),
    .m_axi_ing_arvalid ('0),
    .m_axi_ing_awaddr (m_axi_ing_awaddr),
    .m_axi_ing_awburst (m_axi_ing_awburst),
    .m_axi_ing_awcache ('0),
    .m_axi_ing_awlen (m_axi_ing_awlen),
    .m_axi_ing_awlock ('0),
    .m_axi_ing_awprot ('0),
    .m_axi_ing_awqos ('0),
    .m_axi_ing_awready (m_axi_ing_awready),
    .m_axi_ing_awsize (m_axi_ing_awsize),
    .m_axi_ing_awvalid (m_axi_ing_awvalid),
    .m_axi_ing_bready (m_axi_ing_bready),
    .m_axi_ing_bresp (m_axi_ing_bresp),
    .m_axi_ing_bvalid (m_axi_ing_bvalid),
    .m_axi_ing_rready ('0),
    .m_axi_ing_wdata (m_axi_ing_wdata),
    .m_axi_ing_wlast (m_axi_ing_wlast),
    .m_axi_ing_wready (m_axi_ing_wready),
    .m_axi_ing_wstrb (m_axi_ing_wstrb),
    .m_axi_ing_wvalid (m_axi_ing_wvalid),
    .mdio0_s_axi_araddr (mdio0_s_axi_araddr),
    .mdio0_s_axi_arready (mdio0_s_axi_arready),
    .mdio0_s_axi_arvalid (mdio0_s_axi_arvalid),
    .mdio0_s_axi_awaddr (mdio0_s_axi_awaddr),
    .mdio0_s_axi_awready (mdio0_s_axi_awready),
    .mdio0_s_axi_awvalid (mdio0_s_axi_awvalid),
    .mdio0_s_axi_bready (mdio0_s_axi_bready),
    .mdio0_s_axi_bresp (mdio0_s_axi_bresp),
    .mdio0_s_axi_bvalid (mdio0_s_axi_bvalid),
    .mdio0_s_axi_rdata (mdio0_s_axi_rdata),
    .mdio0_s_axi_rready (mdio0_s_axi_rready),
    .mdio0_s_axi_rresp (mdio0_s_axi_rresp),
    .mdio0_s_axi_rvalid (mdio0_s_axi_rvalid),
    .mdio0_s_axi_wdata (mdio0_s_axi_wdata),
    .mdio0_s_axi_wready (mdio0_s_axi_wready),
    .mdio0_s_axi_wstrb (mdio0_s_axi_wstrb),
    .mdio0_s_axi_wvalid (mdio0_s_axi_wvalid),
    .mdio1_s_axi_araddr (mdio1_s_axi_araddr),
    .mdio1_s_axi_arready (mdio1_s_axi_arready),
    .mdio1_s_axi_arvalid (mdio1_s_axi_arvalid),
    .mdio1_s_axi_awaddr (mdio1_s_axi_awaddr),
    .mdio1_s_axi_awready (mdio1_s_axi_awready),
    .mdio1_s_axi_awvalid (mdio1_s_axi_awvalid),
    .mdio1_s_axi_bready (mdio1_s_axi_bready),
    .mdio1_s_axi_bresp (mdio1_s_axi_bresp),
    .mdio1_s_axi_bvalid (mdio1_s_axi_bvalid),
    .mdio1_s_axi_rdata (mdio1_s_axi_rdata),
    .mdio1_s_axi_rready (mdio1_s_axi_rready),
    .mdio1_s_axi_rresp (mdio1_s_axi_rresp),
    .mdio1_s_axi_rvalid (mdio1_s_axi_rvalid),
    .mdio1_s_axi_wdata (mdio1_s_axi_wdata),
    .mdio1_s_axi_wready (mdio1_s_axi_wready),
    .mdio1_s_axi_wstrb (mdio1_s_axi_wstrb),
    .mdio1_s_axi_wvalid (mdio1_s_axi_wvalid),
    .diag_s_axi_araddr (diag_s_axi_araddr),
    .diag_s_axi_arready (diag_s_axi_arready),
    .diag_s_axi_arvalid (diag_s_axi_arvalid),
    .diag_s_axi_awaddr (diag_s_axi_awaddr),
    .diag_s_axi_awready (diag_s_axi_awready),
    .diag_s_axi_awvalid (diag_s_axi_awvalid),
    .diag_s_axi_bready (diag_s_axi_bready),
    .diag_s_axi_bresp (diag_s_axi_bresp),
    .diag_s_axi_bvalid (diag_s_axi_bvalid),
    .diag_s_axi_rdata (diag_s_axi_rdata),
    .diag_s_axi_rready (diag_s_axi_rready),
    .diag_s_axi_rresp (diag_s_axi_rresp),
    .diag_s_axi_rvalid (diag_s_axi_rvalid),
    .diag_s_axi_wdata (diag_s_axi_wdata),
    .diag_s_axi_wready (diag_s_axi_wready),
    .diag_s_axi_wstrb (diag_s_axi_wstrb),
    .diag_s_axi_wvalid (diag_s_axi_wvalid),
    .pl0_interrupt (pl0_interrupt),
    .pl0_mac_irq (pl0_mac_irq),
    .pl0_s_axi_araddr (pl0_s_axi_araddr),
    .pl0_s_axi_arready (pl0_s_axi_arready),
    .pl0_s_axi_arvalid (pl0_s_axi_arvalid),
    .pl0_s_axi_awaddr (pl0_s_axi_awaddr),
    .pl0_s_axi_awready (pl0_s_axi_awready),
    .pl0_s_axi_awvalid (pl0_s_axi_awvalid),
    .pl0_s_axi_bready (pl0_s_axi_bready),
    .pl0_s_axi_bresp (pl0_s_axi_bresp),
    .pl0_s_axi_bvalid (pl0_s_axi_bvalid),
    .pl0_s_axi_rdata (pl0_s_axi_rdata),
    .pl0_s_axi_rready (pl0_s_axi_rready),
    .pl0_s_axi_rresp (pl0_s_axi_rresp),
    .pl0_s_axi_rvalid (pl0_s_axi_rvalid),
    .pl0_s_axi_wdata (pl0_s_axi_wdata),
    .pl0_s_axi_wready (pl0_s_axi_wready),
    .pl0_s_axi_wstrb (pl0_s_axi_wstrb),
    .pl0_s_axi_wvalid (pl0_s_axi_wvalid),
    .pl1_interrupt (pl1_interrupt),
    .pl1_mac_irq (pl1_mac_irq),
    .pl1_s_axi_araddr (pl1_s_axi_araddr),
    .pl1_s_axi_arready (pl1_s_axi_arready),
    .pl1_s_axi_arvalid (pl1_s_axi_arvalid),
    .pl1_s_axi_awaddr (pl1_s_axi_awaddr),
    .pl1_s_axi_awready (pl1_s_axi_awready),
    .pl1_s_axi_awvalid (pl1_s_axi_awvalid),
    .pl1_s_axi_bready (pl1_s_axi_bready),
    .pl1_s_axi_bresp (pl1_s_axi_bresp),
    .pl1_s_axi_bvalid (pl1_s_axi_bvalid),
    .pl1_s_axi_rdata (pl1_s_axi_rdata),
    .pl1_s_axi_rready (pl1_s_axi_rready),
    .pl1_s_axi_rresp (pl1_s_axi_rresp),
    .pl1_s_axi_rvalid (pl1_s_axi_rvalid),
    .pl1_s_axi_wdata (pl1_s_axi_wdata),
    .pl1_s_axi_wready (pl1_s_axi_wready),
    .pl1_s_axi_wstrb (pl1_s_axi_wstrb),
    .pl1_s_axi_wvalid (pl1_s_axi_wvalid),
    .ps_rst_n (ps_rst_n),
    .sfp_interrupt (sfp_interrupt),
    .sfp_mac_irq (sfp_mac_irq),
    .sfp_s_axi_araddr (sfp_s_axi_araddr),
    .sfp_s_axi_arready (sfp_s_axi_arready),
    .sfp_s_axi_arvalid (sfp_s_axi_arvalid),
    .sfp_s_axi_awaddr (sfp_s_axi_awaddr),
    .sfp_s_axi_awready (sfp_s_axi_awready),
    .sfp_s_axi_awvalid (sfp_s_axi_awvalid),
    .sfp_s_axi_bready (sfp_s_axi_bready),
    .sfp_s_axi_bresp (sfp_s_axi_bresp),
    .sfp_s_axi_bvalid (sfp_s_axi_bvalid),
    .sfp_s_axi_rdata (sfp_s_axi_rdata),
    .sfp_s_axi_rready (sfp_s_axi_rready),
    .sfp_s_axi_rresp (sfp_s_axi_rresp),
    .sfp_s_axi_rvalid (sfp_s_axi_rvalid),
    .sfp_s_axi_wdata (sfp_s_axi_wdata),
    .sfp_s_axi_wready (sfp_s_axi_wready),
    .sfp_s_axi_wstrb (sfp_s_axi_wstrb),
    .sfp_s_axi_wvalid (sfp_s_axi_wvalid)
  );

  kr260_pl_top u_pl (
    .ps_rst_n (ps_rst_n),
    .freerun_clk (freerun_clk),
    .fabric_clk_o (fabric_clk_o),
    .fabric_rst_n_o (fabric_rst_n_o),
    .pl0_ref_clk_25m (pl0_ref_clk_25m),
    .pl0_rgmii_txd (pl0_rgmii_txd),
    .pl0_rgmii_tx_ctl (pl0_rgmii_tx_ctl),
    .pl0_rgmii_txc (pl0_rgmii_txc),
    .pl0_rgmii_rxd (pl0_rgmii_rxd),
    .pl0_rgmii_rx_ctl (pl0_rgmii_rx_ctl),
    .pl0_rgmii_rxc (pl0_rgmii_rxc),
    .pl0_mdio (pl0_mdio),
    .pl0_mdc (pl0_mdc),
    .pl0_phy_reset_n (pl0_phy_reset_n),
    .pl1_ref_clk_25m (pl1_ref_clk_25m),
    .pl1_rgmii_txd (pl1_rgmii_txd),
    .pl1_rgmii_tx_ctl (pl1_rgmii_tx_ctl),
    .pl1_rgmii_txc (pl1_rgmii_txc),
    .pl1_rgmii_rxd (pl1_rgmii_rxd),
    .pl1_rgmii_rx_ctl (pl1_rgmii_rx_ctl),
    .pl1_rgmii_rxc (pl1_rgmii_rxc),
    .pl1_mdio (pl1_mdio),
    .pl1_mdc (pl1_mdc),
    .pl1_phy_reset_n (pl1_phy_reset_n),
    .sfp_refclk_p (sfp_refclk_p),
    .sfp_refclk_n (sfp_refclk_n),
    .sfp_txp (sfp_txp),
    .sfp_txn (sfp_txn),
    .sfp_rxp (sfp_rxp),
    .sfp_rxn (sfp_rxn),
    .sfp_los (sfp_los),
    .sfp_mod_abs (sfp_mod_abs),
    .sfp_tx_fault (sfp_tx_fault),
    .sfp_tx_disable (sfp_tx_disable),
    .sfp_led (sfp_led),
    .link_irq (link_irq),
    .mdio0_s_axi_awaddr (mdio0_s_axi_awaddr[7:0]),
    .mdio0_s_axi_awvalid (mdio0_s_axi_awvalid),
    .mdio0_s_axi_awready (mdio0_s_axi_awready),
    .mdio0_s_axi_wdata (mdio0_s_axi_wdata),
    .mdio0_s_axi_wstrb (mdio0_s_axi_wstrb),
    .mdio0_s_axi_wvalid (mdio0_s_axi_wvalid),
    .mdio0_s_axi_wready (mdio0_s_axi_wready),
    .mdio0_s_axi_bresp (mdio0_s_axi_bresp),
    .mdio0_s_axi_bvalid (mdio0_s_axi_bvalid),
    .mdio0_s_axi_bready (mdio0_s_axi_bready),
    .mdio0_s_axi_araddr (mdio0_s_axi_araddr[7:0]),
    .mdio0_s_axi_arvalid (mdio0_s_axi_arvalid),
    .mdio0_s_axi_arready (mdio0_s_axi_arready),
    .mdio0_s_axi_rdata (mdio0_s_axi_rdata),
    .mdio0_s_axi_rresp (mdio0_s_axi_rresp),
    .mdio0_s_axi_rvalid (mdio0_s_axi_rvalid),
    .mdio0_s_axi_rready (mdio0_s_axi_rready),
    .mdio1_s_axi_awaddr (mdio1_s_axi_awaddr[7:0]),
    .mdio1_s_axi_awvalid (mdio1_s_axi_awvalid),
    .mdio1_s_axi_awready (mdio1_s_axi_awready),
    .mdio1_s_axi_wdata (mdio1_s_axi_wdata),
    .mdio1_s_axi_wstrb (mdio1_s_axi_wstrb),
    .mdio1_s_axi_wvalid (mdio1_s_axi_wvalid),
    .mdio1_s_axi_wready (mdio1_s_axi_wready),
    .mdio1_s_axi_bresp (mdio1_s_axi_bresp),
    .mdio1_s_axi_bvalid (mdio1_s_axi_bvalid),
    .mdio1_s_axi_bready (mdio1_s_axi_bready),
    .mdio1_s_axi_araddr (mdio1_s_axi_araddr[7:0]),
    .mdio1_s_axi_arvalid (mdio1_s_axi_arvalid),
    .mdio1_s_axi_arready (mdio1_s_axi_arready),
    .mdio1_s_axi_rdata (mdio1_s_axi_rdata),
    .mdio1_s_axi_rresp (mdio1_s_axi_rresp),
    .mdio1_s_axi_rvalid (mdio1_s_axi_rvalid),
    .mdio1_s_axi_rready (mdio1_s_axi_rready),
    .diag_s_axi_awaddr (diag_s_axi_awaddr[7:0]),
    .diag_s_axi_awvalid (diag_s_axi_awvalid),
    .diag_s_axi_awready (diag_s_axi_awready),
    .diag_s_axi_wdata (diag_s_axi_wdata),
    .diag_s_axi_wstrb (diag_s_axi_wstrb),
    .diag_s_axi_wvalid (diag_s_axi_wvalid),
    .diag_s_axi_wready (diag_s_axi_wready),
    .diag_s_axi_bresp (diag_s_axi_bresp),
    .diag_s_axi_bvalid (diag_s_axi_bvalid),
    .diag_s_axi_bready (diag_s_axi_bready),
    .diag_s_axi_araddr (diag_s_axi_araddr[7:0]),
    .diag_s_axi_arvalid (diag_s_axi_arvalid),
    .diag_s_axi_arready (diag_s_axi_arready),
    .diag_s_axi_rdata (diag_s_axi_rdata),
    .diag_s_axi_rresp (diag_s_axi_rresp),
    .diag_s_axi_rvalid (diag_s_axi_rvalid),
    .diag_s_axi_rready (diag_s_axi_rready),
    .axis_clk (axis_clk),
    .axis_rst_n (axis_rst_n),
    .gem0_rx_clk (gem0_rx_clk),
    .gem0_tx_clk (gem0_tx_clk),
    .gem1_rx_clk (gem1_rx_clk),
    .gem1_tx_clk (gem1_tx_clk),
    .gem0_rx_w_data_i (gem0_rx_w_data_i),
    .gem0_rx_w_wr_i (gem0_rx_w_wr_i),
    .gem0_rx_w_sop_i (gem0_rx_w_sop_i),
    .gem0_rx_w_eop_i (gem0_rx_w_eop_i),
    .gem0_rx_w_err_i (gem0_rx_w_err_i),
    .gem0_rx_w_flush_i (gem0_rx_w_flush_i),
    .gem0_rx_w_status_i (gem0_rx_w_status_i),
    .gem0_rx_w_overflow_o (gem0_rx_w_overflow_o),
    .gem0_tx_r_rd_i (gem0_tx_r_rd_i),
    .gem0_tx_r_data_rdy_o (gem0_tx_r_data_rdy_o),
    .gem0_tx_r_valid_o (gem0_tx_r_valid_o),
    .gem0_tx_r_data_o (gem0_tx_r_data_o),
    .gem0_tx_r_sop_o (gem0_tx_r_sop_o),
    .gem0_tx_r_eop_o (gem0_tx_r_eop_o),
    .gem0_tx_r_err_o (gem0_tx_r_err_o),
    .gem0_tx_r_underflow_o (gem0_tx_r_underflow_o),
    .gem0_tx_r_flushed_o (gem0_tx_r_flushed_o),
    .gem0_tx_r_control_o (gem0_tx_r_control_o),
    .gem0_dma_tx_end_tog_i (gem0_dma_tx_end_tog_i),
    .gem0_dma_tx_status_tog_o (gem0_dma_tx_status_tog_o),
    .gem0_tx_r_status_i (gem0_tx_r_status_i),
    .gem1_rx_w_data_i (gem1_rx_w_data_i),
    .gem1_rx_w_wr_i (gem1_rx_w_wr_i),
    .gem1_rx_w_sop_i (gem1_rx_w_sop_i),
    .gem1_rx_w_eop_i (gem1_rx_w_eop_i),
    .gem1_rx_w_err_i (gem1_rx_w_err_i),
    .gem1_rx_w_flush_i (gem1_rx_w_flush_i),
    .gem1_rx_w_status_i (gem1_rx_w_status_i),
    .gem1_rx_w_overflow_o (gem1_rx_w_overflow_o),
    .gem1_tx_r_rd_i (gem1_tx_r_rd_i),
    .gem1_tx_r_data_rdy_o (gem1_tx_r_data_rdy_o),
    .gem1_tx_r_valid_o (gem1_tx_r_valid_o),
    .gem1_tx_r_data_o (gem1_tx_r_data_o),
    .gem1_tx_r_sop_o (gem1_tx_r_sop_o),
    .gem1_tx_r_eop_o (gem1_tx_r_eop_o),
    .gem1_tx_r_err_o (gem1_tx_r_err_o),
    .gem1_tx_r_underflow_o (gem1_tx_r_underflow_o),
    .gem1_tx_r_flushed_o (gem1_tx_r_flushed_o),
    .gem1_tx_r_control_o (gem1_tx_r_control_o),
    .gem1_dma_tx_end_tog_i (gem1_dma_tx_end_tog_i),
    .gem1_dma_tx_status_tog_o (gem1_dma_tx_status_tog_o),
    .gem1_tx_r_status_i (gem1_tx_r_status_i),
    .pl0_s_axi_awaddr (pl0_s_axi_awaddr[17:0]),
    .pl0_s_axi_awvalid (pl0_s_axi_awvalid),
    .pl0_s_axi_awready (pl0_s_axi_awready),
    .pl0_s_axi_wdata (pl0_s_axi_wdata),
    .pl0_s_axi_wstrb (pl0_s_axi_wstrb),
    .pl0_s_axi_wvalid (pl0_s_axi_wvalid),
    .pl0_s_axi_wready (pl0_s_axi_wready),
    .pl0_s_axi_bresp (pl0_s_axi_bresp),
    .pl0_s_axi_bvalid (pl0_s_axi_bvalid),
    .pl0_s_axi_bready (pl0_s_axi_bready),
    .pl0_s_axi_araddr (pl0_s_axi_araddr[17:0]),
    .pl0_s_axi_arvalid (pl0_s_axi_arvalid),
    .pl0_s_axi_arready (pl0_s_axi_arready),
    .pl0_s_axi_rdata (pl0_s_axi_rdata),
    .pl0_s_axi_rresp (pl0_s_axi_rresp),
    .pl0_s_axi_rvalid (pl0_s_axi_rvalid),
    .pl0_s_axi_rready (pl0_s_axi_rready),
    .pl0_interrupt (pl0_interrupt),
    .pl0_mac_irq (pl0_mac_irq),
    .pl1_s_axi_awaddr (pl1_s_axi_awaddr[17:0]),
    .pl1_s_axi_awvalid (pl1_s_axi_awvalid),
    .pl1_s_axi_awready (pl1_s_axi_awready),
    .pl1_s_axi_wdata (pl1_s_axi_wdata),
    .pl1_s_axi_wstrb (pl1_s_axi_wstrb),
    .pl1_s_axi_wvalid (pl1_s_axi_wvalid),
    .pl1_s_axi_wready (pl1_s_axi_wready),
    .pl1_s_axi_bresp (pl1_s_axi_bresp),
    .pl1_s_axi_bvalid (pl1_s_axi_bvalid),
    .pl1_s_axi_bready (pl1_s_axi_bready),
    .pl1_s_axi_araddr (pl1_s_axi_araddr[17:0]),
    .pl1_s_axi_arvalid (pl1_s_axi_arvalid),
    .pl1_s_axi_arready (pl1_s_axi_arready),
    .pl1_s_axi_rdata (pl1_s_axi_rdata),
    .pl1_s_axi_rresp (pl1_s_axi_rresp),
    .pl1_s_axi_rvalid (pl1_s_axi_rvalid),
    .pl1_s_axi_rready (pl1_s_axi_rready),
    .pl1_interrupt (pl1_interrupt),
    .pl1_mac_irq (pl1_mac_irq),
    .sfp_s_axi_awaddr (sfp_s_axi_awaddr[17:0]),
    .sfp_s_axi_awvalid (sfp_s_axi_awvalid),
    .sfp_s_axi_awready (sfp_s_axi_awready),
    .sfp_s_axi_wdata (sfp_s_axi_wdata),
    .sfp_s_axi_wstrb (sfp_s_axi_wstrb),
    .sfp_s_axi_wvalid (sfp_s_axi_wvalid),
    .sfp_s_axi_wready (sfp_s_axi_wready),
    .sfp_s_axi_bresp (sfp_s_axi_bresp),
    .sfp_s_axi_bvalid (sfp_s_axi_bvalid),
    .sfp_s_axi_bready (sfp_s_axi_bready),
    .sfp_s_axi_araddr (sfp_s_axi_araddr[17:0]),
    .sfp_s_axi_arvalid (sfp_s_axi_arvalid),
    .sfp_s_axi_arready (sfp_s_axi_arready),
    .sfp_s_axi_rdata (sfp_s_axi_rdata),
    .sfp_s_axi_rresp (sfp_s_axi_rresp),
    .sfp_s_axi_rvalid (sfp_s_axi_rvalid),
    .sfp_s_axi_rready (sfp_s_axi_rready),
    .sfp_interrupt (sfp_interrupt),
    .sfp_mac_irq (sfp_mac_irq),
    .cpu_s_axis_tdata (cpu_s_axis_tdata),
    .cpu_s_axis_tkeep (cpu_s_axis_tkeep),
    .cpu_s_axis_tvalid (cpu_s_axis_tvalid),
    .cpu_s_axis_tlast (cpu_s_axis_tlast),
    .cpu_s_axis_tready (cpu_s_axis_tready),
    .cpu_m_axis_tdata (cpu_m_axis_tdata),
    .cpu_m_axis_tkeep (cpu_m_axis_tkeep),
    .cpu_m_axis_tvalid (cpu_m_axis_tvalid),
    .cpu_m_axis_tlast (cpu_m_axis_tlast),
    .cpu_m_axis_tready (cpu_m_axis_tready),
    .m_axi_ing_awaddr (m_axi_ing_awaddr),
    .m_axi_ing_awlen (m_axi_ing_awlen),
    .m_axi_ing_awsize (m_axi_ing_awsize),
    .m_axi_ing_awburst (m_axi_ing_awburst),
    .m_axi_ing_awvalid (m_axi_ing_awvalid),
    .m_axi_ing_awready (m_axi_ing_awready),
    .m_axi_ing_wdata (m_axi_ing_wdata),
    .m_axi_ing_wstrb (m_axi_ing_wstrb),
    .m_axi_ing_wlast (m_axi_ing_wlast),
    .m_axi_ing_wvalid (m_axi_ing_wvalid),
    .m_axi_ing_wready (m_axi_ing_wready),
    .m_axi_ing_bid ('0),
    .m_axi_ing_bresp (m_axi_ing_bresp),
    .m_axi_ing_bvalid (m_axi_ing_bvalid),
    .m_axi_ing_bready (m_axi_ing_bready),
    .m_axi_egr_araddr (m_axi_egr_araddr),
    .m_axi_egr_arlen (m_axi_egr_arlen),
    .m_axi_egr_arsize (m_axi_egr_arsize),
    .m_axi_egr_arburst (m_axi_egr_arburst),
    .m_axi_egr_arvalid (m_axi_egr_arvalid),
    .m_axi_egr_arready (m_axi_egr_arready),
    .m_axi_egr_rid ('0),
    .m_axi_egr_rdata (m_axi_egr_rdata),
    .m_axi_egr_rresp (m_axi_egr_rresp),
    .m_axi_egr_rlast (m_axi_egr_rlast),
    .m_axi_egr_rvalid (m_axi_egr_rvalid),
    .m_axi_egr_rready (m_axi_egr_rready),
    .m_axi_cpu_awaddr (m_axi_cpu_awaddr),
    .m_axi_cpu_awlen (m_axi_cpu_awlen),
    .m_axi_cpu_awsize (m_axi_cpu_awsize),
    .m_axi_cpu_awburst (m_axi_cpu_awburst),
    .m_axi_cpu_awvalid (m_axi_cpu_awvalid),
    .m_axi_cpu_awready (m_axi_cpu_awready),
    .m_axi_cpu_wdata (m_axi_cpu_wdata),
    .m_axi_cpu_wstrb (m_axi_cpu_wstrb),
    .m_axi_cpu_wlast (m_axi_cpu_wlast),
    .m_axi_cpu_wvalid (m_axi_cpu_wvalid),
    .m_axi_cpu_wready (m_axi_cpu_wready),
    .m_axi_cpu_bid ('0),
    .m_axi_cpu_bresp (m_axi_cpu_bresp),
    .m_axi_cpu_bvalid (m_axi_cpu_bvalid),
    .m_axi_cpu_bready (m_axi_cpu_bready),
    .m_axi_cpu_araddr (m_axi_cpu_araddr),
    .m_axi_cpu_arlen (m_axi_cpu_arlen),
    .m_axi_cpu_arsize (m_axi_cpu_arsize),
    .m_axi_cpu_arburst (m_axi_cpu_arburst),
    .m_axi_cpu_arvalid (m_axi_cpu_arvalid),
    .m_axi_cpu_arready (m_axi_cpu_arready),
    .m_axi_cpu_rid ('0),
    .m_axi_cpu_rdata (m_axi_cpu_rdata),
    .m_axi_cpu_rresp (m_axi_cpu_rresp),
    .m_axi_cpu_rlast (m_axi_cpu_rlast),
    .m_axi_cpu_rvalid (m_axi_cpu_rvalid),
    .m_axi_cpu_rready (m_axi_cpu_rready)
  );

endmodule
