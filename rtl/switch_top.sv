// Compatibility assembly of the reusable IP blocks. Public board/simulation ABI unchanged.
module switch_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  import mac_table_pkg::*;
#(
  // age_tick's clock divider (see below); overridable so a testbench can
  // use a small value instead of the real ~4Hz-at-100MHz divide count,
  // which is far too slow to usefully simulate
  parameter bit STATS_DDR = 0,
  parameter bit STATS_DEBUG = 0,
  parameter int AGE_TICK_DIVIDE_COUNT = 100_000_000 / 4,
  // Simulation defaults; the board top supplies the 125 MHz timer values.
  parameter int SFP_AN_BREAK_LINK_CYCLES = 8,
  parameter int SFP_AN_LINK_TIMER_CYCLES = 8,
  parameter int SFP_AN_IDLE_DETECT_CYCLES = 8
) (
  input wire stats_request,
  input wire [7:0] stats_index,
  output wire stats_ack,
  output wire [31:0] stats_value,
  input  logic clk,      // fabric clock (100 MHz) -- shared by everything
  input  logic rst_n,

  // MAC AXI4-Stream + AXI4-Lite clock (150 MHz), shared by all 3 PL
  // GMII/SFP MAC instances
  input  logic axis_clk,
  input  logic axis_rst_n,

  // GMII-side / GTH-parallel-interface-side clocks -- one per physical
  // transceiver, since each is driven by its own independent PHY/GTH lane
  input  logic gtx_clk_pl0,
  input  logic gtx_clk_pl1,
  input  logic gtx_clk_sfp,
  input  logic gtx_rst_n_sfp, // pl0/pl1 have no GMII-side reset pin of
                               // their own (see pl_gmii_mac_top.sv); the
                               // SFP's PCS logic needs one (see
                               // sfp_port_top.sv)

  // SFP's actual GTH-parallel-interface clock (62.5 MHz, = gtx_clk_sfp/2,
  // phase-related -- not an independent oscillator; see
  // sfp_1000base_x_pcs.sv's header for why this is a separate domain
  // from gtx_clk_sfp). No PL GMII counterpart -- GMII's parallel
  // interface IS the physical pins, there's no transceiver stage.
  input  logic gth_clk_sfp,
  input  logic gth_rst_n_sfp,

  // shared functional-enable input to all 3 open_eth_mac_1g_switch
  // instances (pl0/pl1/sfp) -- see pl_gmii_mac_top.sv's header; no
  // evidence any real system needs these independently controlled
  input  logic mac_clk_en,

  // PS GEM FIFO interface clocks -- one per independent GEM instance
  input  logic gem_rx_clk_ps0,
  input  logic gem_rx_rst_n_ps0,
  input  logic gem_tx_clk_ps0,
  input  logic gem_tx_rst_n_ps0,
  input  logic gem_rx_clk_ps1,
  input  logic gem_rx_rst_n_ps1,
  input  logic gem_tx_clk_ps1,
  input  logic gem_tx_rst_n_ps1,

  // MAC address table: aging schedule input, still software-configurable
  // (see header note); age_tick_i itself is generated internally below
  input  logic [AGE_W-1:0] default_age_i,

  // CPU-maintained per-port link state (asynchronous to `clk`: driven from the
  // AXI-Lite clock domain). Port order: 0 PS GEM0, 1 PS GEM1, 2 PL0, 3 PL1,
  // 4 SFP, 5 CPU. link_up_i is a level; link_flush_tog_i flips on every
  // link-down write. A port that is down receives no new frames, its queued
  // frames are drained (buffers released) and its learned MAC entries expire.
  input  logic [NUM_PORTS-1:0] link_up_i,
  input  logic [NUM_PORTS-1:0] link_flush_tog_i,
  output logic                 link_flush_busy_o,

  // Per-port control state for protocols that need to disable data-plane
  // forwarding/learning on a port without touching its physical link state
  // (802.1D STP/RSTP port states; a hook for any similar future protocol --
  // e.g. LACP/LLDP do not need this, they only use ctrl_frame_o/the CPU TX
  // override below, but nothing stops a future protocol from using this
  // too). Async (AXI-Lite clock domain), synchronized inside this module;
  // both default enabled, matching this design's behavior before this
  // feature existed. A reserved-control-block frame (STP BPDUs, LACP/OAM,
  // LLDP -- see mac_addr_resolver.sv's header) always reaches the CPU
  // regardless of fwd_en_i; only ordinary data-plane forwarding is gated.
  input  logic [NUM_PORTS-1:0] learn_en_i,
  input  logic [NUM_PORTS-1:0] fwd_en_i,

  // One-cycle-per-frame, held for that frame's dest_mask_valid_o lifetime:
  // which ports just received a reserved-control-block frame. A hook for a
  // future per-port control-frame counter/interrupt; nothing here consumes
  // it.
  output logic [NUM_PORTS-1:0] ctrl_frame_o,

  // CPU TX uses per-frame metadata in its DMA stream; see cpu_tx_framer.sv.

  // Ingress-port tag for CPU-delivered frames: the CPU's inbound stream is a
  // single shared queue fed by all 5 physical ports (plus, in principle, the
  // CPU's own loopback slot, which never actually happens -- see
  // ingress_top.sv), so without this a control protocol has no way to know
  // which physical port a frame it just received arrived on. Pushed (clk
  // domain) exactly once per frame this module hands to the CPU DMA, in the
  // same order cpu_dma_rd.sv will stream them out -- see the async_fifo
  // instance below for why this ordering guarantee holds. Read side is
  // axis_clk domain (this module already takes axis_clk as a port), a plain
  // same-clock producer the AXI-Lite side (rx_diag_regs, also axis_clk) can
  // pop directly with no further synchronization.
  output logic [PORT_ID_W-1:0] cpu_rx_ingress_port_o,
  output logic                 cpu_rx_ingress_valid_o,
  input  logic                 cpu_rx_ingress_pop_i,

  // ---------------------------------------------------------------------
  // PS GEM0 FIFO interface (gem_rx_clk_ps0/gem_tx_clk_ps0 domains)
  // ---------------------------------------------------------------------
  input  logic [7:0]  gem0_rx_w_data_i,
  input  logic        gem0_rx_w_wr_i,
  input  logic        gem0_rx_w_sop_i,
  input  logic        gem0_rx_w_eop_i,
  input  logic        gem0_rx_w_err_i,
  input  logic        gem0_rx_w_flush_i,
  input  logic [44:0] gem0_rx_w_status_i,
  output logic        gem0_rx_w_overflow_o,
  output logic [44:0] gem0_rx_w_status_o,
  input  logic        gem0_tx_r_rd_i,
  output logic        gem0_tx_r_data_rdy_o,
  output logic        gem0_tx_r_valid_o,
  output logic [7:0]  gem0_tx_r_data_o,
  output logic        gem0_tx_r_sop_o,
  output logic        gem0_tx_r_eop_o,
  output logic        gem0_tx_r_err_o,
  output logic        gem0_tx_r_underflow_o,
  output logic        gem0_tx_r_flushed_o,
  output logic        gem0_tx_r_control_o,
  input  logic        gem0_dma_tx_end_tog_i,
  output logic        gem0_dma_tx_status_tog_o,
  input  logic [3:0]  gem0_tx_r_status_i,

  // ---------------------------------------------------------------------
  // PS GEM1 FIFO interface (gem_rx_clk_ps1/gem_tx_clk_ps1 domains)
  // ---------------------------------------------------------------------
  input  logic [7:0]  gem1_rx_w_data_i,
  input  logic        gem1_rx_w_wr_i,
  input  logic        gem1_rx_w_sop_i,
  input  logic        gem1_rx_w_eop_i,
  input  logic        gem1_rx_w_err_i,
  input  logic        gem1_rx_w_flush_i,
  input  logic [44:0] gem1_rx_w_status_i,
  output logic        gem1_rx_w_overflow_o,
  output logic [44:0] gem1_rx_w_status_o,
  input  logic        gem1_tx_r_rd_i,
  output logic        gem1_tx_r_data_rdy_o,
  output logic        gem1_tx_r_valid_o,
  output logic [7:0]  gem1_tx_r_data_o,
  output logic        gem1_tx_r_sop_o,
  output logic        gem1_tx_r_eop_o,
  output logic        gem1_tx_r_err_o,
  output logic        gem1_tx_r_underflow_o,
  output logic        gem1_tx_r_flushed_o,
  output logic        gem1_tx_r_control_o,
  input  logic        gem1_dma_tx_end_tog_i,
  output logic        gem1_dma_tx_status_tog_o,
  input  logic [3:0]  gem1_tx_r_status_i,

  // ---------------------------------------------------------------------
  // PL GMII0 (gtx_clk_pl0 domain) + its AXI4-Lite (axis_clk domain)
  // ---------------------------------------------------------------------
  input  logic [7:0] pl0_gmii_rxd,
  input  logic        pl0_gmii_rx_dv,
  input  logic        pl0_gmii_rx_er,
  output logic [7:0] pl0_gmii_txd,
  output logic        pl0_gmii_tx_en,
  output logic        pl0_gmii_tx_er,
  input  logic [17:0] pl0_s_axi_awaddr,
  input  logic         pl0_s_axi_awvalid,
  output logic         pl0_s_axi_awready,
  input  logic [31:0] pl0_s_axi_wdata,
  input  logic [3:0]  pl0_s_axi_wstrb,
  input  logic         pl0_s_axi_wvalid,
  output logic         pl0_s_axi_wready,
  output logic [1:0]  pl0_s_axi_bresp,
  output logic         pl0_s_axi_bvalid,
  input  logic         pl0_s_axi_bready,
  input  logic [17:0] pl0_s_axi_araddr,
  input  logic         pl0_s_axi_arvalid,
  output logic         pl0_s_axi_arready,
  output logic [31:0] pl0_s_axi_rdata,
  output logic [1:0]  pl0_s_axi_rresp,
  output logic         pl0_s_axi_rvalid,
  input  logic         pl0_s_axi_rready,
  output logic pl0_interrupt,
  output logic pl0_mac_irq,

  // ---------------------------------------------------------------------
  // PL GMII1 (gtx_clk_pl1 domain) + its AXI4-Lite (axis_clk domain)
  // ---------------------------------------------------------------------
  input  logic [7:0] pl1_gmii_rxd,
  input  logic        pl1_gmii_rx_dv,
  input  logic        pl1_gmii_rx_er,
  output logic [7:0] pl1_gmii_txd,
  output logic        pl1_gmii_tx_en,
  output logic        pl1_gmii_tx_er,
  input  logic [17:0] pl1_s_axi_awaddr,
  input  logic         pl1_s_axi_awvalid,
  output logic         pl1_s_axi_awready,
  input  logic [31:0] pl1_s_axi_wdata,
  input  logic [3:0]  pl1_s_axi_wstrb,
  input  logic         pl1_s_axi_wvalid,
  output logic         pl1_s_axi_wready,
  output logic [1:0]  pl1_s_axi_bresp,
  output logic         pl1_s_axi_bvalid,
  input  logic         pl1_s_axi_bready,
  input  logic [17:0] pl1_s_axi_araddr,
  input  logic         pl1_s_axi_arvalid,
  output logic         pl1_s_axi_arready,
  output logic [31:0] pl1_s_axi_rdata,
  output logic [1:0]  pl1_s_axi_rresp,
  output logic         pl1_s_axi_rvalid,
  input  logic         pl1_s_axi_rready,
  output logic pl1_interrupt,
  output logic pl1_mac_irq,

  // ---------------------------------------------------------------------
  // SFP0 GTH-parallel-interface (gtx_clk_sfp domain) + its AXI4-Lite
  // (axis_clk domain)
  // ---------------------------------------------------------------------
  output logic [15:0] sfp_txdata_o,
  output logic [1:0]  sfp_txcharisk_o,
  input  logic [15:0] sfp_rxdata_i,
  input  logic [1:0]  sfp_rxcharisk_i,
  input  logic [1:0]  sfp_rxdisperr_i,
  input  logic [1:0]  sfp_rxnotintable_i,
  output logic        sfp_sync_ok_o,
  output logic        sfp_an_link_up_o,
  output logic        sfp_an_duplex_full_o,
  output logic [1:0]  sfp_an_pause_o,
  output logic        sfp_an_remote_fault_o,
  input  logic [17:0] sfp_s_axi_awaddr,
  input  logic         sfp_s_axi_awvalid,
  output logic         sfp_s_axi_awready,
  input  logic [31:0] sfp_s_axi_wdata,
  input  logic [3:0]  sfp_s_axi_wstrb,
  input  logic         sfp_s_axi_wvalid,
  output logic         sfp_s_axi_wready,
  output logic [1:0]  sfp_s_axi_bresp,
  output logic         sfp_s_axi_bvalid,
  input  logic         sfp_s_axi_bready,
  input  logic [17:0] sfp_s_axi_araddr,
  input  logic         sfp_s_axi_arvalid,
  output logic         sfp_s_axi_arready,
  output logic [31:0] sfp_s_axi_rdata,
  output logic [1:0]  sfp_s_axi_rresp,
  output logic         sfp_s_axi_rvalid,
  input  logic         sfp_s_axi_rready,
  output logic sfp_interrupt,
  output logic sfp_mac_irq,

  // ---------------------------------------------------------------------
  // CPU port's own AXI4-Stream boundary (clk domain) -- to/from a
  // Vivado-configured AXI DMA IP (Scatter/Gather mode), not instantiated
  // here (see cpu_port_top.sv's header)
  // ---------------------------------------------------------------------
  input  logic [15:0] cpu_s_axis_tdata,
  input  logic [1:0]  cpu_s_axis_tkeep,
  input  logic         cpu_s_axis_tvalid,
  input  logic         cpu_s_axis_tlast,
  output logic         cpu_s_axis_tready,
  output logic [15:0] cpu_m_axis_tdata,
  output logic [1:0]  cpu_m_axis_tkeep,
  output logic         cpu_m_axis_tvalid,
  output logic         cpu_m_axis_tlast,
  input  logic         cpu_m_axis_tready,

  // ---------------------------------------------------------------------
  // AXI4 masters to PS DDR (see header note: reconciling these onto one
  // path is a system-integration/interconnect concern, not built here)
  // ---------------------------------------------------------------------
  output logic [AXI_ID_W-1:0]   m_axi_ing_awid,
  output logic [AXI_ADDR_W-1:0] m_axi_ing_awaddr,
  output logic [7:0]            m_axi_ing_awlen,
  output logic [2:0]            m_axi_ing_awsize,
  output logic [1:0]            m_axi_ing_awburst,
  output logic                  m_axi_ing_awvalid,
  input  logic                  m_axi_ing_awready,
  output logic [AXI_DATA_W-1:0] m_axi_ing_wdata,
  output logic [AXI_STRB_W-1:0] m_axi_ing_wstrb,
  output logic                  m_axi_ing_wlast,
  output logic                  m_axi_ing_wvalid,
  input  logic                  m_axi_ing_wready,
  input  logic [AXI_ID_W-1:0]   m_axi_ing_bid,
  input  logic [1:0]            m_axi_ing_bresp,
  input  logic                  m_axi_ing_bvalid,
  output logic                  m_axi_ing_bready,

  output logic [AXI_ID_W-1:0]   m_axi_egr_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_egr_araddr,
  output logic [7:0]            m_axi_egr_arlen,
  output logic [2:0]            m_axi_egr_arsize,
  output logic [1:0]            m_axi_egr_arburst,
  output logic                  m_axi_egr_arvalid,
  input  logic                  m_axi_egr_arready,
  input  logic [AXI_ID_W-1:0]   m_axi_egr_rid,
  input  logic [AXI_DATA_W-1:0] m_axi_egr_rdata,
  input  logic [1:0]            m_axi_egr_rresp,
  input  logic                  m_axi_egr_rlast,
  input  logic                  m_axi_egr_rvalid,
  output logic                  m_axi_egr_rready,

  output logic [AXI_ID_W-1:0]   m_axi_cpu_awid,
  output logic [AXI_ADDR_W-1:0] m_axi_cpu_awaddr,
  output logic [7:0]            m_axi_cpu_awlen,
  output logic [2:0]            m_axi_cpu_awsize,
  output logic [1:0]            m_axi_cpu_awburst,
  output logic                  m_axi_cpu_awvalid,
  input  logic                  m_axi_cpu_awready,
  output logic [AXI_DATA_W-1:0] m_axi_cpu_wdata,
  output logic [AXI_STRB_W-1:0] m_axi_cpu_wstrb,
  output logic                  m_axi_cpu_wlast,
  output logic                  m_axi_cpu_wvalid,
  input  logic                  m_axi_cpu_wready,
  input  logic [AXI_ID_W-1:0]   m_axi_cpu_bid,
  input  logic [1:0]            m_axi_cpu_bresp,
  input  logic                  m_axi_cpu_bvalid,
  output logic                  m_axi_cpu_bready,

  output logic [AXI_ID_W-1:0]   m_axi_cpu_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_cpu_araddr,
  output logic [7:0]            m_axi_cpu_arlen,
  output logic [2:0]            m_axi_cpu_arsize,
  output logic [1:0]            m_axi_cpu_arburst,
  output logic                  m_axi_cpu_arvalid,
  input  logic                  m_axi_cpu_arready,
  input  logic [AXI_ID_W-1:0]   m_axi_cpu_rid,
  input  logic [AXI_DATA_W-1:0] m_axi_cpu_rdata,
  input  logic [1:0]            m_axi_cpu_rresp,
  input  logic                  m_axi_cpu_rlast,
  input  logic                  m_axi_cpu_rvalid,
  output logic                  m_axi_cpu_rready
);

  logic [NUM_PHYS_PORTS-1:0][15:0] phy_s_axis_tdata;
  logic [NUM_PHYS_PORTS-1:0][1:0]  phy_s_axis_tkeep;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tvalid;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tlast;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tuser;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tready;
  logic [NUM_PHYS_PORTS-1:0][15:0] phy_m_axis_tdata;
  logic [NUM_PHYS_PORTS-1:0][1:0]  phy_m_axis_tkeep;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tvalid;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tlast;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tready;
  wire [12:0] stats_req, stats_acks;
  wire [12:0][31:0] stats_values;
  switch_fabric #(.STATS_DDR(STATS_DDR), .STATS_DEBUG(STATS_DEBUG),
    .AGE_TICK_DIVIDE_COUNT(AGE_TICK_DIVIDE_COUNT)) u_fabric (
    .clk(clk),
    .rst_n(rst_n),
    .axis_clk(axis_clk),
    .axis_rst_n(axis_rst_n),
    .default_age_i(default_age_i),
    .link_up_i(link_up_i),
    .link_flush_tog_i(link_flush_tog_i),
    .link_flush_busy_o(link_flush_busy_o),
    .learn_en_i(learn_en_i),
    .fwd_en_i(fwd_en_i),
    .ctrl_frame_o(ctrl_frame_o),
    .cpu_rx_ingress_port_o(cpu_rx_ingress_port_o),
    .cpu_rx_ingress_valid_o(cpu_rx_ingress_valid_o),
    .cpu_rx_ingress_pop_i(cpu_rx_ingress_pop_i),
    .cpu_s_axis_tdata(cpu_s_axis_tdata),
    .cpu_s_axis_tkeep(cpu_s_axis_tkeep),
    .cpu_s_axis_tvalid(cpu_s_axis_tvalid),
    .cpu_s_axis_tlast(cpu_s_axis_tlast),
    .cpu_s_axis_tready(cpu_s_axis_tready),
    .cpu_m_axis_tdata(cpu_m_axis_tdata),
    .cpu_m_axis_tkeep(cpu_m_axis_tkeep),
    .cpu_m_axis_tvalid(cpu_m_axis_tvalid),
    .cpu_m_axis_tlast(cpu_m_axis_tlast),
    .cpu_m_axis_tready(cpu_m_axis_tready),
    .m_axi_ing_awid(m_axi_ing_awid),
    .m_axi_ing_awaddr(m_axi_ing_awaddr),
    .m_axi_ing_awlen(m_axi_ing_awlen),
    .m_axi_ing_awsize(m_axi_ing_awsize),
    .m_axi_ing_awburst(m_axi_ing_awburst),
    .m_axi_ing_awvalid(m_axi_ing_awvalid),
    .m_axi_ing_awready(m_axi_ing_awready),
    .m_axi_ing_wdata(m_axi_ing_wdata),
    .m_axi_ing_wstrb(m_axi_ing_wstrb),
    .m_axi_ing_wlast(m_axi_ing_wlast),
    .m_axi_ing_wvalid(m_axi_ing_wvalid),
    .m_axi_ing_wready(m_axi_ing_wready),
    .m_axi_ing_bid(m_axi_ing_bid),
    .m_axi_ing_bresp(m_axi_ing_bresp),
    .m_axi_ing_bvalid(m_axi_ing_bvalid),
    .m_axi_ing_bready(m_axi_ing_bready),
    .m_axi_egr_arid(m_axi_egr_arid),
    .m_axi_egr_araddr(m_axi_egr_araddr),
    .m_axi_egr_arlen(m_axi_egr_arlen),
    .m_axi_egr_arsize(m_axi_egr_arsize),
    .m_axi_egr_arburst(m_axi_egr_arburst),
    .m_axi_egr_arvalid(m_axi_egr_arvalid),
    .m_axi_egr_arready(m_axi_egr_arready),
    .m_axi_egr_rid(m_axi_egr_rid),
    .m_axi_egr_rdata(m_axi_egr_rdata),
    .m_axi_egr_rresp(m_axi_egr_rresp),
    .m_axi_egr_rlast(m_axi_egr_rlast),
    .m_axi_egr_rvalid(m_axi_egr_rvalid),
    .m_axi_egr_rready(m_axi_egr_rready),
    .m_axi_cpu_awid(m_axi_cpu_awid),
    .m_axi_cpu_awaddr(m_axi_cpu_awaddr),
    .m_axi_cpu_awlen(m_axi_cpu_awlen),
    .m_axi_cpu_awsize(m_axi_cpu_awsize),
    .m_axi_cpu_awburst(m_axi_cpu_awburst),
    .m_axi_cpu_awvalid(m_axi_cpu_awvalid),
    .m_axi_cpu_awready(m_axi_cpu_awready),
    .m_axi_cpu_wdata(m_axi_cpu_wdata),
    .m_axi_cpu_wstrb(m_axi_cpu_wstrb),
    .m_axi_cpu_wlast(m_axi_cpu_wlast),
    .m_axi_cpu_wvalid(m_axi_cpu_wvalid),
    .m_axi_cpu_wready(m_axi_cpu_wready),
    .m_axi_cpu_bid(m_axi_cpu_bid),
    .m_axi_cpu_bresp(m_axi_cpu_bresp),
    .m_axi_cpu_bvalid(m_axi_cpu_bvalid),
    .m_axi_cpu_bready(m_axi_cpu_bready),
    .m_axi_cpu_arid(m_axi_cpu_arid),
    .m_axi_cpu_araddr(m_axi_cpu_araddr),
    .m_axi_cpu_arlen(m_axi_cpu_arlen),
    .m_axi_cpu_arsize(m_axi_cpu_arsize),
    .m_axi_cpu_arburst(m_axi_cpu_arburst),
    .m_axi_cpu_arvalid(m_axi_cpu_arvalid),
    .m_axi_cpu_arready(m_axi_cpu_arready),
    .m_axi_cpu_rid(m_axi_cpu_rid),
    .m_axi_cpu_rdata(m_axi_cpu_rdata),
    .m_axi_cpu_rresp(m_axi_cpu_rresp),
    .m_axi_cpu_rlast(m_axi_cpu_rlast),
    .m_axi_cpu_rvalid(m_axi_cpu_rvalid),
    .m_axi_cpu_rready(m_axi_cpu_rready),
    .s00_axis_tdata(phy_s_axis_tdata[0]),
    .s01_axis_tdata(phy_s_axis_tdata[1]),
    .s02_axis_tdata(phy_s_axis_tdata[2]),
    .s03_axis_tdata(phy_s_axis_tdata[3]),
    .s04_axis_tdata(phy_s_axis_tdata[4]),
    .s00_axis_tkeep(phy_s_axis_tkeep[0]),
    .s01_axis_tkeep(phy_s_axis_tkeep[1]),
    .s02_axis_tkeep(phy_s_axis_tkeep[2]),
    .s03_axis_tkeep(phy_s_axis_tkeep[3]),
    .s04_axis_tkeep(phy_s_axis_tkeep[4]),
    .s00_axis_tvalid(phy_s_axis_tvalid[0]),
    .s01_axis_tvalid(phy_s_axis_tvalid[1]),
    .s02_axis_tvalid(phy_s_axis_tvalid[2]),
    .s03_axis_tvalid(phy_s_axis_tvalid[3]),
    .s04_axis_tvalid(phy_s_axis_tvalid[4]),
    .s00_axis_tlast(phy_s_axis_tlast[0]),
    .s01_axis_tlast(phy_s_axis_tlast[1]),
    .s02_axis_tlast(phy_s_axis_tlast[2]),
    .s03_axis_tlast(phy_s_axis_tlast[3]),
    .s04_axis_tlast(phy_s_axis_tlast[4]),
    .s00_axis_tuser(phy_s_axis_tuser[0]),
    .s01_axis_tuser(phy_s_axis_tuser[1]),
    .s02_axis_tuser(phy_s_axis_tuser[2]),
    .s03_axis_tuser(phy_s_axis_tuser[3]),
    .s04_axis_tuser(phy_s_axis_tuser[4]),
    .s00_axis_tready(phy_s_axis_tready[0]),
    .s01_axis_tready(phy_s_axis_tready[1]),
    .s02_axis_tready(phy_s_axis_tready[2]),
    .s03_axis_tready(phy_s_axis_tready[3]),
    .s04_axis_tready(phy_s_axis_tready[4]),
    .m00_axis_tdata(phy_m_axis_tdata[0]),
    .m01_axis_tdata(phy_m_axis_tdata[1]),
    .m02_axis_tdata(phy_m_axis_tdata[2]),
    .m03_axis_tdata(phy_m_axis_tdata[3]),
    .m04_axis_tdata(phy_m_axis_tdata[4]),
    .m00_axis_tkeep(phy_m_axis_tkeep[0]),
    .m01_axis_tkeep(phy_m_axis_tkeep[1]),
    .m02_axis_tkeep(phy_m_axis_tkeep[2]),
    .m03_axis_tkeep(phy_m_axis_tkeep[3]),
    .m04_axis_tkeep(phy_m_axis_tkeep[4]),
    .m00_axis_tvalid(phy_m_axis_tvalid[0]),
    .m01_axis_tvalid(phy_m_axis_tvalid[1]),
    .m02_axis_tvalid(phy_m_axis_tvalid[2]),
    .m03_axis_tvalid(phy_m_axis_tvalid[3]),
    .m04_axis_tvalid(phy_m_axis_tvalid[4]),
    .m00_axis_tlast(phy_m_axis_tlast[0]),
    .m01_axis_tlast(phy_m_axis_tlast[1]),
    .m02_axis_tlast(phy_m_axis_tlast[2]),
    .m03_axis_tlast(phy_m_axis_tlast[3]),
    .m04_axis_tlast(phy_m_axis_tlast[4]),
    .m00_axis_tready(phy_m_axis_tready[0]),
    .m01_axis_tready(phy_m_axis_tready[1]),
    .m02_axis_tready(phy_m_axis_tready[2]),
    .m03_axis_tready(phy_m_axis_tready[3]),
    .m04_axis_tready(phy_m_axis_tready[4]),
    .stats_req(stats_req[12:7]),
    .stats_select(stats_index[3:0]),
    .stats_acks(stats_acks[12:7]),
    .stats_values(stats_values[12:7])
  );

  switch_gem_port u_ps_gem0 (
    .stats_req(stats_req[1:0]), .stats_select(stats_index[3:0]),
    .stats_acks(stats_acks[1:0]), .stats_values(stats_values[1:0]),
    .clk              (clk),
    .rst_n            (rst_n),
    .gem_rx_clk       (gem_rx_clk_ps0),
    .gem_rx_rst_n     (gem_rx_rst_n_ps0),
    .gem_tx_clk       (gem_tx_clk_ps0),
    .gem_tx_rst_n     (gem_tx_rst_n_ps0),
    .rx_w_data_i      (gem0_rx_w_data_i),
    .rx_w_wr_i        (gem0_rx_w_wr_i),
    .rx_w_sop_i       (gem0_rx_w_sop_i),
    .rx_w_eop_i       (gem0_rx_w_eop_i),
    .rx_w_err_i       (gem0_rx_w_err_i),
    .rx_w_flush_i     (gem0_rx_w_flush_i),
    .rx_w_status_i    (gem0_rx_w_status_i),
    .rx_w_overflow_o  (gem0_rx_w_overflow_o),
    .m_axis_tdata     (phy_s_axis_tdata[0]),
    .m_axis_tkeep     (phy_s_axis_tkeep[0]),
    .m_axis_tvalid    (phy_s_axis_tvalid[0]),
    .m_axis_tlast     (phy_s_axis_tlast[0]),
    .m_axis_tuser     (phy_s_axis_tuser[0]),
    .m_axis_tready    (phy_s_axis_tready[0]),
    .rx_w_status_o    (gem0_rx_w_status_o),
    .s_axis_tdata     (phy_m_axis_tdata[0]),
    .s_axis_tkeep     (phy_m_axis_tkeep[0]),
    .s_axis_tvalid    (phy_m_axis_tvalid[0]),
    .s_axis_tlast     (phy_m_axis_tlast[0]),
    .s_axis_tready    (phy_m_axis_tready[0]),
    .tx_r_rd_i           (gem0_tx_r_rd_i),
    .tx_r_data_rdy_o     (gem0_tx_r_data_rdy_o),
    .tx_r_valid_o        (gem0_tx_r_valid_o),
    .tx_r_data_o         (gem0_tx_r_data_o),
    .tx_r_sop_o          (gem0_tx_r_sop_o),
    .tx_r_eop_o          (gem0_tx_r_eop_o),
    .tx_r_err_o          (gem0_tx_r_err_o),
    .tx_r_underflow_o    (gem0_tx_r_underflow_o),
    .tx_r_flushed_o      (gem0_tx_r_flushed_o),
    .tx_r_control_o      (gem0_tx_r_control_o),
    .dma_tx_end_tog_i    (gem0_dma_tx_end_tog_i),
    .dma_tx_status_tog_o (gem0_dma_tx_status_tog_o),
    .tx_r_status_i       (gem0_tx_r_status_i)
  );


  switch_gem_port u_ps_gem1 (
    .stats_req(stats_req[3:2]), .stats_select(stats_index[3:0]),
    .stats_acks(stats_acks[3:2]), .stats_values(stats_values[3:2]),
    .clk              (clk),
    .rst_n            (rst_n),
    .gem_rx_clk       (gem_rx_clk_ps1),
    .gem_rx_rst_n     (gem_rx_rst_n_ps1),
    .gem_tx_clk       (gem_tx_clk_ps1),
    .gem_tx_rst_n     (gem_tx_rst_n_ps1),
    .rx_w_data_i      (gem1_rx_w_data_i),
    .rx_w_wr_i        (gem1_rx_w_wr_i),
    .rx_w_sop_i       (gem1_rx_w_sop_i),
    .rx_w_eop_i       (gem1_rx_w_eop_i),
    .rx_w_err_i       (gem1_rx_w_err_i),
    .rx_w_flush_i     (gem1_rx_w_flush_i),
    .rx_w_status_i    (gem1_rx_w_status_i),
    .rx_w_overflow_o  (gem1_rx_w_overflow_o),
    .m_axis_tdata     (phy_s_axis_tdata[1]),
    .m_axis_tkeep     (phy_s_axis_tkeep[1]),
    .m_axis_tvalid    (phy_s_axis_tvalid[1]),
    .m_axis_tlast     (phy_s_axis_tlast[1]),
    .m_axis_tuser     (phy_s_axis_tuser[1]),
    .m_axis_tready    (phy_s_axis_tready[1]),
    .rx_w_status_o    (gem1_rx_w_status_o),
    .s_axis_tdata     (phy_m_axis_tdata[1]),
    .s_axis_tkeep     (phy_m_axis_tkeep[1]),
    .s_axis_tvalid    (phy_m_axis_tvalid[1]),
    .s_axis_tlast     (phy_m_axis_tlast[1]),
    .s_axis_tready    (phy_m_axis_tready[1]),
    .tx_r_rd_i           (gem1_tx_r_rd_i),
    .tx_r_data_rdy_o     (gem1_tx_r_data_rdy_o),
    .tx_r_valid_o        (gem1_tx_r_valid_o),
    .tx_r_data_o         (gem1_tx_r_data_o),
    .tx_r_sop_o          (gem1_tx_r_sop_o),
    .tx_r_eop_o          (gem1_tx_r_eop_o),
    .tx_r_err_o          (gem1_tx_r_err_o),
    .tx_r_underflow_o    (gem1_tx_r_underflow_o),
    .tx_r_flushed_o      (gem1_tx_r_flushed_o),
    .tx_r_control_o      (gem1_tx_r_control_o),
    .dma_tx_end_tog_i    (gem1_dma_tx_end_tog_i),
    .dma_tx_status_tog_o (gem1_dma_tx_status_tog_o),
    .tx_r_status_i       (gem1_tx_r_status_i)
  );


  pl_gmii_mac_top u_pl_gmii0 (
    .stats_request(stats_req[4]), .stats_select(stats_index[3:0]),
    .stats_ack(stats_acks[4]), .stats_value(stats_values[4]),
    .clk               (clk),
    .rst_n             (rst_n),
    .axis_clk          (axis_clk),
    .axis_rst_n        (axis_rst_n),
    .gtx_clk           (gtx_clk_pl0),
    .clk_en            (mac_clk_en),
    .gmii_rxd          (pl0_gmii_rxd),
    .gmii_rx_dv        (pl0_gmii_rx_dv),
    .gmii_rx_er        (pl0_gmii_rx_er),
    .gmii_txd          (pl0_gmii_txd),
    .gmii_tx_en        (pl0_gmii_tx_en),
    .gmii_tx_er        (pl0_gmii_tx_er),
    .m_axis_tdata      (phy_s_axis_tdata[2]),
    .m_axis_tkeep      (phy_s_axis_tkeep[2]),
    .m_axis_tvalid     (phy_s_axis_tvalid[2]),
    .m_axis_tlast      (phy_s_axis_tlast[2]),
    .m_axis_tuser      (phy_s_axis_tuser[2]),
    .m_axis_tready     (phy_s_axis_tready[2]),
    .s_axis_tdata      (phy_m_axis_tdata[2]),
    .s_axis_tkeep      (phy_m_axis_tkeep[2]),
    .s_axis_tvalid     (phy_m_axis_tvalid[2]),
    .s_axis_tlast      (phy_m_axis_tlast[2]),
    .s_axis_tready     (phy_m_axis_tready[2]),
    .s_axi_awaddr      (pl0_s_axi_awaddr),
    .s_axi_awvalid     (pl0_s_axi_awvalid),
    .s_axi_awready     (pl0_s_axi_awready),
    .s_axi_wdata       (pl0_s_axi_wdata),
    .s_axi_wstrb       (pl0_s_axi_wstrb),
    .s_axi_wvalid      (pl0_s_axi_wvalid),
    .s_axi_wready      (pl0_s_axi_wready),
    .s_axi_bresp       (pl0_s_axi_bresp),
    .s_axi_bvalid      (pl0_s_axi_bvalid),
    .s_axi_bready      (pl0_s_axi_bready),
    .s_axi_araddr      (pl0_s_axi_araddr),
    .s_axi_arvalid     (pl0_s_axi_arvalid),
    .s_axi_arready     (pl0_s_axi_arready),
    .s_axi_rdata       (pl0_s_axi_rdata),
    .s_axi_rresp       (pl0_s_axi_rresp),
    .s_axi_rvalid      (pl0_s_axi_rvalid),
    .s_axi_rready      (pl0_s_axi_rready),
    .interrupt         (pl0_interrupt),
    .mac_irq           (pl0_mac_irq)
  );


  pl_gmii_mac_top u_pl_gmii1 (
    .stats_request(stats_req[5]), .stats_select(stats_index[3:0]),
    .stats_ack(stats_acks[5]), .stats_value(stats_values[5]),
    .clk               (clk),
    .rst_n             (rst_n),
    .axis_clk          (axis_clk),
    .axis_rst_n        (axis_rst_n),
    .gtx_clk           (gtx_clk_pl1),
    .clk_en            (mac_clk_en),
    .gmii_rxd          (pl1_gmii_rxd),
    .gmii_rx_dv        (pl1_gmii_rx_dv),
    .gmii_rx_er        (pl1_gmii_rx_er),
    .gmii_txd          (pl1_gmii_txd),
    .gmii_tx_en        (pl1_gmii_tx_en),
    .gmii_tx_er        (pl1_gmii_tx_er),
    .m_axis_tdata      (phy_s_axis_tdata[3]),
    .m_axis_tkeep      (phy_s_axis_tkeep[3]),
    .m_axis_tvalid     (phy_s_axis_tvalid[3]),
    .m_axis_tlast      (phy_s_axis_tlast[3]),
    .m_axis_tuser      (phy_s_axis_tuser[3]),
    .m_axis_tready     (phy_s_axis_tready[3]),
    .s_axis_tdata      (phy_m_axis_tdata[3]),
    .s_axis_tkeep      (phy_m_axis_tkeep[3]),
    .s_axis_tvalid     (phy_m_axis_tvalid[3]),
    .s_axis_tlast      (phy_m_axis_tlast[3]),
    .s_axis_tready     (phy_m_axis_tready[3]),
    .s_axi_awaddr      (pl1_s_axi_awaddr),
    .s_axi_awvalid     (pl1_s_axi_awvalid),
    .s_axi_awready     (pl1_s_axi_awready),
    .s_axi_wdata       (pl1_s_axi_wdata),
    .s_axi_wstrb       (pl1_s_axi_wstrb),
    .s_axi_wvalid      (pl1_s_axi_wvalid),
    .s_axi_wready      (pl1_s_axi_wready),
    .s_axi_bresp       (pl1_s_axi_bresp),
    .s_axi_bvalid      (pl1_s_axi_bvalid),
    .s_axi_bready      (pl1_s_axi_bready),
    .s_axi_araddr      (pl1_s_axi_araddr),
    .s_axi_arvalid     (pl1_s_axi_arvalid),
    .s_axi_arready     (pl1_s_axi_arready),
    .s_axi_rdata       (pl1_s_axi_rdata),
    .s_axi_rresp       (pl1_s_axi_rresp),
    .s_axi_rvalid      (pl1_s_axi_rvalid),
    .s_axi_rready      (pl1_s_axi_rready),
    .interrupt         (pl1_interrupt),
    .mac_irq           (pl1_mac_irq)
  );


  sfp_port_top #(
    .AN_BREAK_LINK_CYCLES(SFP_AN_BREAK_LINK_CYCLES),
    .AN_LINK_TIMER_CYCLES(SFP_AN_LINK_TIMER_CYCLES),
    .AN_IDLE_DETECT_CYCLES(SFP_AN_IDLE_DETECT_CYCLES)
  ) u_sfp0 (
    .stats_request(stats_req[6]), .stats_select(stats_index[3:0]),
    .stats_ack(stats_acks[6]), .stats_value(stats_values[6]),
    .clk              (clk),
    .rst_n            (rst_n),
    .axis_clk         (axis_clk),
    .axis_rst_n       (axis_rst_n),
    .gtx_clk          (gtx_clk_sfp),
    .gtx_rst_n        (gtx_rst_n_sfp),
    .gth_clk          (gth_clk_sfp),
    .gth_rst_n        (gth_rst_n_sfp),
    .clk_en           (mac_clk_en),
    .txdata_o         (sfp_txdata_o),
    .txcharisk_o      (sfp_txcharisk_o),
    .rxdata_i         (sfp_rxdata_i),
    .rxcharisk_i      (sfp_rxcharisk_i),
    .rxdisperr_i      (sfp_rxdisperr_i),
    .rxnotintable_i   (sfp_rxnotintable_i),
    .sync_ok_o        (sfp_sync_ok_o),
    .an_link_up_o      (sfp_an_link_up_o),
    .an_duplex_full_o  (sfp_an_duplex_full_o),
    .an_pause_o        (sfp_an_pause_o),
    .an_remote_fault_o (sfp_an_remote_fault_o),
    .m_axis_tdata     (phy_s_axis_tdata[4]),
    .m_axis_tkeep     (phy_s_axis_tkeep[4]),
    .m_axis_tvalid    (phy_s_axis_tvalid[4]),
    .m_axis_tlast     (phy_s_axis_tlast[4]),
    .m_axis_tuser     (phy_s_axis_tuser[4]),
    .m_axis_tready    (phy_s_axis_tready[4]),
    .s_axis_tdata     (phy_m_axis_tdata[4]),
    .s_axis_tkeep     (phy_m_axis_tkeep[4]),
    .s_axis_tvalid    (phy_m_axis_tvalid[4]),
    .s_axis_tlast     (phy_m_axis_tlast[4]),
    .s_axis_tready    (phy_m_axis_tready[4]),
    .s_axi_awaddr     (sfp_s_axi_awaddr),
    .s_axi_awvalid    (sfp_s_axi_awvalid),
    .s_axi_awready    (sfp_s_axi_awready),
    .s_axi_wdata      (sfp_s_axi_wdata),
    .s_axi_wstrb      (sfp_s_axi_wstrb),
    .s_axi_wvalid     (sfp_s_axi_wvalid),
    .s_axi_wready     (sfp_s_axi_wready),
    .s_axi_bresp      (sfp_s_axi_bresp),
    .s_axi_bvalid     (sfp_s_axi_bvalid),
    .s_axi_bready     (sfp_s_axi_bready),
    .s_axi_araddr     (sfp_s_axi_araddr),
    .s_axi_arvalid    (sfp_s_axi_arvalid),
    .s_axi_arready    (sfp_s_axi_arready),
    .s_axi_rdata      (sfp_s_axi_rdata),
    .s_axi_rresp      (sfp_s_axi_rresp),
    .s_axi_rvalid     (sfp_s_axi_rvalid),
    .s_axi_rready     (sfp_s_axi_rready),
    .interrupt        (sfp_interrupt),
    .mac_irq          (sfp_mac_irq)
  );

  // Statistics mailbox selects one source bank. Select is held throughout
  // the four-phase CDC handshake by rx_diag_regs.
  for (genvar k=0;k<13;k=k+1) begin : stats_decode
    assign stats_req[k] = stats_request && stats_index[7:4] == k;
  end
  assign stats_ack = stats_index[7:4] < 13 ? stats_acks[stats_index[7:4]] : stats_request;
  assign stats_value = stats_index[7:4] < 13 ? stats_values[stats_index[7:4]] : 0;

endmodule
