// switch_top.sv
//
// Top-level switch: joins every subsystem built and tested independently
// elsewhere in this project, which is the piece that had been missing.
//
//   - ingress_top.sv / egress_top.sv: 5 physical ports' ingress/egress
//     DMA + the one shared buf_mgr_core instance (owned by ingress_top.sv;
//     egress_top.sv's dequeue/release passthrough is wired to it here)
//   - cpu_port_top.sv: the CPU port (buf_mgr_pkg::NUM_PORTS' index 5),
//     its alloc/enqueue wired to ingress_top.sv's cpu_* passthrough and
//     its dequeue/release wired to egress_top.sv's cpu_* passthrough
//   - mac_forwarding_top.sv: the MAC learn/lookup/aging table, snooping
//     every port's ingress AXI4-Stream and driving every port's
//     dest_mask_i/dest_mask_valid_i (ingress_top.sv for ports 0-4,
//     cpu_port_top.sv for port 5)
//   - 2x ps_gem_axis_bridge.sv (PS GEM0/GEM1), 2x pl_gmii_mac_top.sv
//     (PL GMII0/GMII1), 1x sfp_port_top.sv (SFP): the 5 physical ports'
//     own MAC/PCS front-ends
//   - a free-running clock divider generating mac_forwarding_top's
//     age_tick_i (~4 Hz) directly from the fabric clock -- the "simple
//     clock divider" this project's aging schedule was always meant to
//     run from (see mac_table_pkg.sv's AGE_TICKS_PER_SWEEP note)
//
// Port numbering (fixed by axi_dma_pkg.sv's own NUM_PHYS_PORTS comment,
// "PS0, PS1, PL0, PL1, SFP0", plus buf_mgr_pkg::NUM_PORTS' 6th slot):
//   0 = PS GEM0   1 = PS GEM1   2 = PL GMII0   3 = PL GMII1
//   4 = SFP0      5 = CPU
//
// Deliberately NOT resolved here (each already flagged at its own
// boundary, carried up to this level unchanged):
//   - the AXI4 write/read masters from ingress_top.sv, egress_top.sv, and
//     cpu_port_top.sv (2 more) all still need to reach PS DDR through
//     some AXI interconnect/crossbar -- a system-integration concern, not
//     built here; all 4 are exposed as this module's own separate masters
//   - the CPU port's own s_axis_*/m_axis_* AXI4-Stream boundary still
//     needs a Vivado-configured AXI DMA IP (Scatter/Gather mode) on the
//     other end -- see cpu_port_top.sv's header
//   - the SFP port's GTHE4_CHANNEL transceiver primitive and Clause 37
//     autonegotiation -- see sfp_port_top.sv's header; sync_ok_o here is
//     PCS code-group sync only, not a negotiated link
//   - each MAC's own AXI4-Lite (register/statistics) port -- exposed
//     separately per instance (pl_gmii0/pl_gmii1/sfp), no CPU-facing
//     register-access architecture decided yet
//   - default_age_i -- exposed as a runtime input, matching
//     mac_addr_table_top.sv's own "software-configurable" design intent;
//     no fixed value chosen here

module switch_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  import mac_table_pkg::*;
#(
  // age_tick's clock divider (see below); overridable so a testbench can
  // use a small value instead of the real ~4Hz-at-62.5MHz divide count,
  // which is far too slow to usefully simulate
  parameter int AGE_TICK_DIVIDE_COUNT = 62_500_000 / 4
) (
  input  logic clk,      // fabric clock (62.5 MHz) -- shared by everything
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
  input  logic gem_clk_ps0,
  input  logic gem_rst_n_ps0,
  input  logic gem_clk_ps1,
  input  logic gem_rst_n_ps1,

  // MAC address table: aging schedule input, still software-configurable
  // (see header note); age_tick_i itself is generated internally below
  input  logic [AGE_W-1:0] default_age_i,

  // ---------------------------------------------------------------------
  // PS GEM0 FIFO interface (gem_clk_ps0 domain)
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
  // PS GEM1 FIFO interface (gem_clk_ps1 domain)
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

  // =========================================================================
  // age_tick: free-running clock divider off the fabric clock (clk,
  // 62.5 MHz by default), pulsing age_tick for exactly 1 cycle every
  // AGE_TICK_DIVIDE_COUNT cycles (~1/4 second at the default count) --
  // mac_addr_table_top.sv synchronizes/edge-detects this itself (it need
  // not already be clean in this clock domain, though it already is), so
  // a plain counter-driven pulse is all that's needed here.
  // =========================================================================
  localparam int DIVIDE_CNT_W = $clog2(AGE_TICK_DIVIDE_COUNT);

  logic [DIVIDE_CNT_W-1:0] age_div_cnt_q;
  logic                    age_tick;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      age_div_cnt_q <= '0;
      age_tick      <= 1'b0;
    end else if (age_div_cnt_q == DIVIDE_CNT_W'(AGE_TICK_DIVIDE_COUNT - 1)) begin
      age_div_cnt_q <= '0;
      age_tick      <= 1'b1;
    end else begin
      age_div_cnt_q <= age_div_cnt_q + 1'b1;
      age_tick      <= 1'b0;
    end
  end

  // =========================================================================
  // buf_mgr_core dequeue/release passthrough: ingress_top.sv <-> egress_top.sv
  // =========================================================================
  logic [NUM_PORTS-1:0]               dequeue_req;
  logic [NUM_PORTS-1:0]               dequeue_valid;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length;
  logic [NUM_PORTS-1:0]               release_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid;
  logic [NUM_PORTS-1:0]               release_gnt;

  // =========================================================================
  // CPU port alloc/enqueue (ingress side) <-> ingress_top.sv's cpu_* ports
  // =========================================================================
  logic                cpu_alloc_req, cpu_alloc_gnt;
  logic [BUF_ID_W-1:0] cpu_alloc_bufid;
  logic                     cpu_enqueue_req;
  logic [BUF_ID_W-1:0]      cpu_enqueue_bufid;
  logic [LENGTH_W-1:0]      cpu_enqueue_length;
  logic [NUM_PORTS-1:0]     cpu_enqueue_destmask;
  logic                     cpu_enqueue_gnt;

  // =========================================================================
  // CPU port dequeue/release (egress side) <-> egress_top.sv's cpu_* ports
  // =========================================================================
  logic                cpu_dequeue_valid;
  logic [BUF_ID_W-1:0] cpu_dequeue_bufid;
  logic [LENGTH_W-1:0] cpu_dequeue_length;
  logic                cpu_dequeue_req;
  logic                cpu_release_req;
  logic [BUF_ID_W-1:0] cpu_release_bufid;
  logic                cpu_release_gnt;

  // =========================================================================
  // Per-physical-port ingress AXI4-Stream (MAC -> ingress_top.sv), indexed
  // 0=PS GEM0, 1=PS GEM1, 2=PL GMII0, 3=PL GMII1, 4=SFP0
  // =========================================================================
  logic [NUM_PHYS_PORTS-1:0][15:0] phy_s_axis_tdata;
  logic [NUM_PHYS_PORTS-1:0][1:0]  phy_s_axis_tkeep;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tvalid;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tlast;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tuser;
  logic [NUM_PHYS_PORTS-1:0]       phy_s_axis_tready;

  // Per-physical-port egress AXI4-Stream (egress_top.sv -> MAC)
  logic [NUM_PHYS_PORTS-1:0][15:0] phy_m_axis_tdata;
  logic [NUM_PHYS_PORTS-1:0][1:0]  phy_m_axis_tkeep;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tvalid;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tlast;
  logic [NUM_PHYS_PORTS-1:0]       phy_m_axis_tready;

  // =========================================================================
  // Forwarding decision, all NUM_PORTS (0-4 physical, 5 CPU)
  // =========================================================================
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] dest_mask;
  logic [NUM_PORTS-1:0]                dest_mask_valid;

  // mac_forwarding_top's snoop inputs mirror the same s_axis_* wires
  // feeding ingress_top.sv (ports 0-4) and cpu_port_top.sv (port 5)
  logic [NUM_PORTS-1:0][15:0] fwd_s_axis_tdata;
  logic [NUM_PORTS-1:0][1:0]  fwd_s_axis_tkeep;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tvalid;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tlast;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tready;

  assign fwd_s_axis_tdata[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tdata;
  assign fwd_s_axis_tkeep[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tkeep;
  assign fwd_s_axis_tvalid[NUM_PHYS_PORTS-1:0] = phy_s_axis_tvalid;
  assign fwd_s_axis_tlast[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tlast;
  assign fwd_s_axis_tready[NUM_PHYS_PORTS-1:0] = phy_s_axis_tready;

  assign fwd_s_axis_tdata[5]  = cpu_s_axis_tdata;
  assign fwd_s_axis_tkeep[5]  = cpu_s_axis_tkeep;
  assign fwd_s_axis_tvalid[5] = cpu_s_axis_tvalid;
  assign fwd_s_axis_tlast[5]  = cpu_s_axis_tlast;
  assign fwd_s_axis_tready[5] = cpu_s_axis_tready;

  // =========================================================================
  // ingress_top.sv (owns buf_mgr_core)
  // =========================================================================
  ingress_top u_ingress_top (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .s_axis_tdata              (phy_s_axis_tdata),
    .s_axis_tkeep              (phy_s_axis_tkeep),
    .s_axis_tvalid             (phy_s_axis_tvalid),
    .s_axis_tlast              (phy_s_axis_tlast),
    .s_axis_tuser              (phy_s_axis_tuser),
    .s_axis_tready             (phy_s_axis_tready),
    .dest_mask_i               (dest_mask[NUM_PHYS_PORTS-1:0]),
    .dest_mask_valid_i         (dest_mask_valid[NUM_PHYS_PORTS-1:0]),
    .m_axi_awid                (m_axi_ing_awid),
    .m_axi_awaddr              (m_axi_ing_awaddr),
    .m_axi_awlen               (m_axi_ing_awlen),
    .m_axi_awsize              (m_axi_ing_awsize),
    .m_axi_awburst             (m_axi_ing_awburst),
    .m_axi_awvalid             (m_axi_ing_awvalid),
    .m_axi_awready             (m_axi_ing_awready),
    .m_axi_wdata               (m_axi_ing_wdata),
    .m_axi_wstrb               (m_axi_ing_wstrb),
    .m_axi_wlast               (m_axi_ing_wlast),
    .m_axi_wvalid              (m_axi_ing_wvalid),
    .m_axi_wready              (m_axi_ing_wready),
    .m_axi_bid                 (m_axi_ing_bid),
    .m_axi_bresp                (m_axi_ing_bresp),
    .m_axi_bvalid                (m_axi_ing_bvalid),
    .m_axi_bready                (m_axi_ing_bready),
    .dequeue_req_i_passthru      (dequeue_req),
    .dequeue_valid_o_passthru    (dequeue_valid),
    .dequeue_bufid_o_passthru    (dequeue_bufid),
    .dequeue_length_o_passthru   (dequeue_length),
    .release_req_i_passthru      (release_req),
    .release_bufid_i_passthru    (release_bufid),
    .release_gnt_o_passthru      (release_gnt),
    .cpu_alloc_req_i              (cpu_alloc_req),
    .cpu_alloc_gnt_o              (cpu_alloc_gnt),
    .cpu_alloc_bufid_o            (cpu_alloc_bufid),
    .cpu_enqueue_req_i            (cpu_enqueue_req),
    .cpu_enqueue_bufid_i          (cpu_enqueue_bufid),
    .cpu_enqueue_length_i         (cpu_enqueue_length),
    .cpu_enqueue_destmask_i       (cpu_enqueue_destmask),
    .cpu_enqueue_gnt_o            (cpu_enqueue_gnt)
  );

  // =========================================================================
  // egress_top.sv
  // =========================================================================
  egress_top u_egress_top (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .m_axis_tdata              (phy_m_axis_tdata),
    .m_axis_tkeep              (phy_m_axis_tkeep),
    .m_axis_tvalid             (phy_m_axis_tvalid),
    .m_axis_tlast              (phy_m_axis_tlast),
    .m_axis_tready             (phy_m_axis_tready),
    .m_axi_arid                (m_axi_egr_arid),
    .m_axi_araddr              (m_axi_egr_araddr),
    .m_axi_arlen               (m_axi_egr_arlen),
    .m_axi_arsize              (m_axi_egr_arsize),
    .m_axi_arburst             (m_axi_egr_arburst),
    .m_axi_arvalid             (m_axi_egr_arvalid),
    .m_axi_arready             (m_axi_egr_arready),
    .m_axi_rid                 (m_axi_egr_rid),
    .m_axi_rdata                (m_axi_egr_rdata),
    .m_axi_rresp                (m_axi_egr_rresp),
    .m_axi_rlast                (m_axi_egr_rlast),
    .m_axi_rvalid                (m_axi_egr_rvalid),
    .m_axi_rready                (m_axi_egr_rready),
    .dequeue_req_o_passthru      (dequeue_req),
    .dequeue_valid_i_passthru    (dequeue_valid),
    .dequeue_bufid_i_passthru    (dequeue_bufid),
    .dequeue_length_i_passthru   (dequeue_length),
    .release_req_o_passthru      (release_req),
    .release_bufid_o_passthru    (release_bufid),
    .release_gnt_i_passthru      (release_gnt),
    .cpu_dequeue_valid_o          (cpu_dequeue_valid),
    .cpu_dequeue_bufid_o          (cpu_dequeue_bufid),
    .cpu_dequeue_length_o         (cpu_dequeue_length),
    .cpu_dequeue_req_i            (cpu_dequeue_req),
    .cpu_release_req_i            (cpu_release_req),
    .cpu_release_bufid_i          (cpu_release_bufid),
    .cpu_release_gnt_o            (cpu_release_gnt)
  );

  // =========================================================================
  // cpu_port_top.sv
  // =========================================================================
  cpu_port_top u_cpu_port_top (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .s_axis_tdata           (cpu_s_axis_tdata),
    .s_axis_tkeep           (cpu_s_axis_tkeep),
    .s_axis_tvalid          (cpu_s_axis_tvalid),
    .s_axis_tlast           (cpu_s_axis_tlast),
    .s_axis_tready          (cpu_s_axis_tready),
    .m_axis_tdata           (cpu_m_axis_tdata),
    .m_axis_tkeep           (cpu_m_axis_tkeep),
    .m_axis_tvalid          (cpu_m_axis_tvalid),
    .m_axis_tlast           (cpu_m_axis_tlast),
    .m_axis_tready          (cpu_m_axis_tready),
    .dest_mask_i            (dest_mask[5]),
    .dest_mask_valid_i      (dest_mask_valid[5]),
    .cpu_alloc_req_o        (cpu_alloc_req),
    .cpu_alloc_gnt_i        (cpu_alloc_gnt),
    .cpu_alloc_bufid_i      (cpu_alloc_bufid),
    .cpu_enqueue_req_o      (cpu_enqueue_req),
    .cpu_enqueue_bufid_o    (cpu_enqueue_bufid),
    .cpu_enqueue_length_o   (cpu_enqueue_length),
    .cpu_enqueue_destmask_o (cpu_enqueue_destmask),
    .cpu_enqueue_gnt_i      (cpu_enqueue_gnt),
    .cpu_dequeue_valid_i    (cpu_dequeue_valid),
    .cpu_dequeue_bufid_i    (cpu_dequeue_bufid),
    .cpu_dequeue_length_i   (cpu_dequeue_length),
    .cpu_dequeue_req_o      (cpu_dequeue_req),
    .cpu_release_req_o      (cpu_release_req),
    .cpu_release_bufid_o    (cpu_release_bufid),
    .cpu_release_gnt_i      (cpu_release_gnt),
    .m_axi_awid             (m_axi_cpu_awid),
    .m_axi_awaddr           (m_axi_cpu_awaddr),
    .m_axi_awlen            (m_axi_cpu_awlen),
    .m_axi_awsize           (m_axi_cpu_awsize),
    .m_axi_awburst          (m_axi_cpu_awburst),
    .m_axi_awvalid          (m_axi_cpu_awvalid),
    .m_axi_awready          (m_axi_cpu_awready),
    .m_axi_wdata            (m_axi_cpu_wdata),
    .m_axi_wstrb            (m_axi_cpu_wstrb),
    .m_axi_wlast            (m_axi_cpu_wlast),
    .m_axi_wvalid           (m_axi_cpu_wvalid),
    .m_axi_wready           (m_axi_cpu_wready),
    .m_axi_bid              (m_axi_cpu_bid),
    .m_axi_bresp            (m_axi_cpu_bresp),
    .m_axi_bvalid           (m_axi_cpu_bvalid),
    .m_axi_bready           (m_axi_cpu_bready),
    .m_axi_arid             (m_axi_cpu_arid),
    .m_axi_araddr           (m_axi_cpu_araddr),
    .m_axi_arlen            (m_axi_cpu_arlen),
    .m_axi_arsize           (m_axi_cpu_arsize),
    .m_axi_arburst          (m_axi_cpu_arburst),
    .m_axi_arvalid          (m_axi_cpu_arvalid),
    .m_axi_arready          (m_axi_cpu_arready),
    .m_axi_rid              (m_axi_cpu_rid),
    .m_axi_rdata            (m_axi_cpu_rdata),
    .m_axi_rresp            (m_axi_cpu_rresp),
    .m_axi_rlast            (m_axi_cpu_rlast),
    .m_axi_rvalid           (m_axi_cpu_rvalid),
    .m_axi_rready           (m_axi_cpu_rready)
  );

  // =========================================================================
  // mac_forwarding_top.sv
  // =========================================================================
  mac_forwarding_top u_mac_forwarding_top (
    .clk               (clk),
    .rst_n             (rst_n),
    .age_tick_i        (age_tick),
    .default_age_i     (default_age_i),
    .s_axis_tdata_i    (fwd_s_axis_tdata),
    .s_axis_tkeep_i    (fwd_s_axis_tkeep),
    .s_axis_tvalid_i   (fwd_s_axis_tvalid),
    .s_axis_tlast_i    (fwd_s_axis_tlast),
    .s_axis_tready_i   (fwd_s_axis_tready),
    .dest_mask_o       (dest_mask),
    .dest_mask_valid_o (dest_mask_valid)
  );

  // =========================================================================
  // PS GEM0 (port 0) / PS GEM1 (port 1)
  // =========================================================================
  ps_gem_axis_bridge u_ps_gem0 (
    .clk              (clk),
    .rst_n            (rst_n),
    .gem_clk          (gem_clk_ps0),
    .gem_rst_n        (gem_rst_n_ps0),
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

  ps_gem_axis_bridge u_ps_gem1 (
    .clk              (clk),
    .rst_n            (rst_n),
    .gem_clk          (gem_clk_ps1),
    .gem_rst_n        (gem_rst_n_ps1),
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

  // =========================================================================
  // PL GMII0 (port 2) / PL GMII1 (port 3)
  // =========================================================================
  pl_gmii_mac_top u_pl_gmii0 (
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

  // =========================================================================
  // SFP0 (port 4)
  // =========================================================================
  sfp_port_top u_sfp0 (
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

endmodule
