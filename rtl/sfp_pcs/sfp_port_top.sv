// sfp_port_top.sv
//
// Wraps the KR260's SFP cage Ethernet port: sfp_1000base_x_pcs.sv (Clause
// 36 1000BASE-X PCS -- see that file's header for what it does and does
// NOT include) feeding open_eth_mac_1g_switch (the same destination-
// filter-stripped MAC fork used for the two PL GMII ports -- see
// rtl/pl_gmii/open_eth_mac_1g_switch.sv's header for what changed and
// why), plus the same two width/CDC adapters used there
// (mac_rxd_to_switch_ingress.sv / switch_egress_to_mac_txd.sv) to convert
// the MAC's native 32-bit AXI4-Stream to this switch's 16-bit/62.5MHz
// convention. The MAC's GMII pins connect directly to the PCS's GMII
// side instead of to physical pins -- both use the identical signal
// shape (gmii_txd/tx_en/tx_er, gmii_rxd/rx_dv/rx_er), so no adaptation
// is needed there.
//
// Deliberately NOT included here (separate, later stages -- see
// sfp_1000base_x_pcs.sv's header for the same boundary on the PCS side):
//   - the actual GTHE4_CHANNEL transceiver primitive. This module's
//     txdata_o/txcharisk_o and rxdata_i/rxcharisk_i/rxdisperr_i/
//     rxnotintable_i are the GTH-parallel-interface boundary signals,
//     meant to connect to a GTH wrapper stage, not simulated here.
//   - Clause 37 autonegotiation (link-up/duplex/speed resolution over
//     the /C1//C2/ ordered sets) -- sync_ok_o here only reflects PCS
//     code-group synchronization (Clause 36.2.5.2), not a negotiated link.
//
// Four clock domains: clk/rst_n (fabric, 62.5MHz) for the switch-side
// AXI4-Stream; axis_clk/axis_rst_n (150MHz) for the MAC's AXI4-Stream +
// AXI4-Lite side; gtx_clk/gtx_rst_n (125MHz-class) for the shared
// GMII<->PCS<->GTH-parallel-interface side -- per sfp_1000base_x_pcs.sv's
// own header, its TX and RX parallel interfaces are assumed already in
// this one clock domain (a real GTH's RX side needs its own CDC via the
// hardware RX elastic buffer, deferred to the GTH wrapper stage).
// gtx_rst_n has no counterpart on the physical-pin PL GMII port (GMII
// itself has no reset pin), but the PCS's internal state machines need
// one; it must already be synchronized to gtx_clk by the caller.

module sfp_port_top (
  input  logic clk,          // fabric clock (62.5 MHz)
  input  logic rst_n,
  input  logic axis_clk,     // MAC's AXI4-Stream + AXI4-Lite clock (150 MHz)
  input  logic axis_rst_n,
  input  logic gtx_clk,      // GMII/PCS/GTH-parallel-interface clock (125 MHz)
  input  logic gtx_rst_n,
  input  logic clk_en,

  // GTH TX 8b/10b-assisted parallel interface (-> GTH wrapper, later stage)
  output logic [7:0] txdata_o,
  output logic        txcharisk_o,

  // GTH RX 8b/10b-assisted parallel interface (<- GTH wrapper, later stage)
  input  logic [7:0] rxdata_i,
  input  logic        rxcharisk_i,
  input  logic        rxdisperr_i,
  input  logic        rxnotintable_i,

  // PCS code-group sync status (not a negotiated link -- see header note)
  output logic sync_ok_o,

  // switch ingress AXI4-Stream master, 16-bit, clk domain
  // (-> ingress_port_wr.sv s_axis_*)
  output logic [15:0] m_axis_tdata,
  output logic [1:0]  m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,
  input  logic         m_axis_tready,

  // switch egress AXI4-Stream slave, 16-bit, clk domain
  // (<- egress_port_rd.sv m_axis_*)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // AXI4-Lite register/statistics access, axis_clk domain -- passthrough
  input  logic [17:0] s_axi_awaddr,
  input  logic         s_axi_awvalid,
  output logic         s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic         s_axi_wvalid,
  output logic         s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic         s_axi_bvalid,
  input  logic         s_axi_bready,
  input  logic [17:0] s_axi_araddr,
  input  logic         s_axi_arvalid,
  output logic         s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic         s_axi_rvalid,
  input  logic         s_axi_rready,

  output logic interrupt,
  output logic mac_irq
);

  // MAC <-> PCS GMII, gtx_clk domain
  logic [7:0] gmii_txd;
  logic       gmii_tx_en;
  logic       gmii_tx_er;
  logic [7:0] gmii_rxd;
  logic       gmii_rx_dv;
  logic       gmii_rx_er;

  sfp_1000base_x_pcs u_pcs (
    .clk             (gtx_clk),
    .rst_n           (gtx_rst_n),
    .gmii_txd_i      (gmii_txd),
    .gmii_tx_en_i    (gmii_tx_en),
    .gmii_tx_er_i    (gmii_tx_er),
    .gmii_rxd_o      (gmii_rxd),
    .gmii_rx_dv_o    (gmii_rx_dv),
    .gmii_rx_er_o    (gmii_rx_er),
    .txdata_o        (txdata_o),
    .txcharisk_o     (txcharisk_o),
    .rxdata_i        (rxdata_i),
    .rxcharisk_i     (rxcharisk_i),
    .rxdisperr_i     (rxdisperr_i),
    .rxnotintable_i  (rxnotintable_i),
    .sync_ok_o       (sync_ok_o)
  );

  // MAC <-> ingress adapter (32-bit m_axis_rxd, axis_clk domain)
  logic [31:0] mac_rxd_tdata;
  logic [3:0]  mac_rxd_tkeep;
  logic        mac_rxd_tlast;
  logic        mac_rxd_tvalid;
  logic        mac_rxd_tready;

  // egress adapter <-> MAC (32-bit s_axis_txc/txd, axis_clk domain)
  logic        mac_txc_tvalid;
  logic        mac_txc_tlast;
  logic        mac_txc_tready;
  logic [31:0] mac_txd_tdata;
  logic [3:0]  mac_txd_tkeep;
  logic        mac_txd_tlast;
  logic        mac_txd_tvalid;
  logic        mac_txd_tready;

  // MAC's RX status burst -- drained, never consumed (same rationale as
  // rtl/pl_gmii/pl_gmii_mac_top.sv's identical tie-off)
  logic [31:0] mac_rxs_tdata;
  logic [3:0]  mac_rxs_tkeep;
  logic        mac_rxs_tlast;
  logic        mac_rxs_tvalid;
  wire         mac_rxs_tready = 1'b1;

  open_eth_mac_1g_switch u_mac (
    .axis_clk          (axis_clk),
    .s_axi_lite_clk    (axis_clk),
    .gtx_clk           (gtx_clk),
    .clk_en            (clk_en),
    .axi_txd_arstn     (axis_rst_n),
    .axi_txc_arstn     (axis_rst_n),
    .axi_rxd_arstn     (axis_rst_n),
    .axi_rxs_arstn     (axis_rst_n),
    .s_axi_lite_resetn (axis_rst_n),

    .s_axis_txd_tdata  (mac_txd_tdata),
    .s_axis_txd_tkeep  (mac_txd_tkeep),
    .s_axis_txd_tlast  (mac_txd_tlast),
    .s_axis_txd_tvalid (mac_txd_tvalid),
    .s_axis_txd_tready (mac_txd_tready),

    .s_axis_txc_tdata  ('0),
    .s_axis_txc_tkeep  (4'hf),
    .s_axis_txc_tlast  (mac_txc_tlast),
    .s_axis_txc_tvalid (mac_txc_tvalid),
    .s_axis_txc_tready (mac_txc_tready),

    .m_axis_rxd_tdata  (mac_rxd_tdata),
    .m_axis_rxd_tkeep  (mac_rxd_tkeep),
    .m_axis_rxd_tlast  (mac_rxd_tlast),
    .m_axis_rxd_tvalid (mac_rxd_tvalid),
    .m_axis_rxd_tready (mac_rxd_tready),

    .m_axis_rxs_tdata  (mac_rxs_tdata),
    .m_axis_rxs_tkeep  (mac_rxs_tkeep),
    .m_axis_rxs_tlast  (mac_rxs_tlast),
    .m_axis_rxs_tvalid (mac_rxs_tvalid),
    .m_axis_rxs_tready (mac_rxs_tready),

    .s_axi_awaddr      (s_axi_awaddr),
    .s_axi_awvalid     (s_axi_awvalid),
    .s_axi_awready     (s_axi_awready),
    .s_axi_wdata       (s_axi_wdata),
    .s_axi_wstrb       (s_axi_wstrb),
    .s_axi_wvalid      (s_axi_wvalid),
    .s_axi_wready      (s_axi_wready),
    .s_axi_bresp       (s_axi_bresp),
    .s_axi_bvalid      (s_axi_bvalid),
    .s_axi_bready      (s_axi_bready),
    .s_axi_araddr      (s_axi_araddr),
    .s_axi_arvalid     (s_axi_arvalid),
    .s_axi_arready     (s_axi_arready),
    .s_axi_rdata       (s_axi_rdata),
    .s_axi_rresp       (s_axi_rresp),
    .s_axi_rvalid      (s_axi_rvalid),
    .s_axi_rready      (s_axi_rready),

    .gmii_rxd          (gmii_rxd),
    .gmii_rx_dv        (gmii_rx_dv),
    .gmii_rx_er        (gmii_rx_er),
    .gmii_txd          (gmii_txd),
    .gmii_tx_en        (gmii_tx_en),
    .gmii_tx_er        (gmii_tx_er),

    .interrupt         (interrupt),
    .mac_irq           (mac_irq)
  );

  mac_rxd_to_switch_ingress u_rx_adapt (
    .axis_clk            (axis_clk),
    .axis_rst_n          (axis_rst_n),
    .clk                 (clk),
    .rst_n               (rst_n),
    .m_axis_rxd_tdata_i  (mac_rxd_tdata),
    .m_axis_rxd_tkeep_i  (mac_rxd_tkeep),
    .m_axis_rxd_tlast_i  (mac_rxd_tlast),
    .m_axis_rxd_tvalid_i (mac_rxd_tvalid),
    .m_axis_rxd_tready_o (mac_rxd_tready),
    .s_axis_tdata_o      (m_axis_tdata),
    .s_axis_tkeep_o      (m_axis_tkeep),
    .s_axis_tvalid_o     (m_axis_tvalid),
    .s_axis_tlast_o      (m_axis_tlast),
    .s_axis_tuser_o      (m_axis_tuser),
    .s_axis_tready_i     (m_axis_tready)
  );

  switch_egress_to_mac_txd u_tx_adapt (
    .clk                 (clk),
    .rst_n               (rst_n),
    .axis_clk            (axis_clk),
    .axis_rst_n          (axis_rst_n),
    .s_axis_tdata_i      (s_axis_tdata),
    .s_axis_tkeep_i      (s_axis_tkeep),
    .s_axis_tvalid_i     (s_axis_tvalid),
    .s_axis_tlast_i      (s_axis_tlast),
    .s_axis_tready_o     (s_axis_tready),
    .s_axis_txc_tvalid_o (mac_txc_tvalid),
    .s_axis_txc_tlast_o  (mac_txc_tlast),
    .s_axis_txc_tready_i (mac_txc_tready),
    .s_axis_txd_tdata_o  (mac_txd_tdata),
    .s_axis_txd_tkeep_o  (mac_txd_tkeep),
    .s_axis_txd_tlast_o  (mac_txd_tlast),
    .s_axis_txd_tvalid_o (mac_txd_tvalid),
    .s_axis_txd_tready_i (mac_txd_tready)
  );

endmodule
