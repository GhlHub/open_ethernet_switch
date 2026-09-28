// 10GBASE-R MAC/PCS. clk=125 MHz fabric, axis_clk=management,
// gtx_clk=156.25 MHz TX, gth_clk=156.25 MHz recovered RX.
// Legacy-named charisk ports carry two-bit 64b/66b sync headers in this IP.
module sfp_10g_port #(
  parameter bit DEFAULT_ENABLE = 0,
  parameter int RX_HEALTH_WINDOW = 19531
) (
  input wire stats_request,
  input wire [3:0] stats_select,
  output wire [3:0] stats_activity,
  output wire stats_ack,
  output wire [31:0] stats_value,
  input  logic clk,          // fabric clock (125 MHz)
  input  logic rst_n,
  input  logic axis_clk,     // AXI4-Lite management clock
  input  logic axis_rst_n,
  input  logic gtx_clk,      // PCS transmit clock (156.25 MHz)
  input  logic gtx_rst_n,
  input  logic gth_clk,      // PCS recovered receive clock (156.25 MHz)
  input  logic gth_rst_n,
  input  logic clk_en,

  // GTH TX data and 64b/66b sync header
  output logic [63:0] txdata_o,
  output logic [1:0]  txcharisk_o,

  // GTH RX data and 64b/66b sync header
  input  logic [63:0] rxdata_i,
  input  logic [1:0]  rxcharisk_i,
  input  logic [1:0]  rxdisperr_i,
  input  logic [1:0]  rxnotintable_i,

  // PCS block lock
  output logic sync_ok_o,

  // Legacy status pin names; 10GBASE-R does not use Clause 37 AN
  output logic       an_link_up_o,
  output logic       an_duplex_full_o,
  output logic [1:0] an_pause_o,
  output logic       an_remote_fault_o,

  // switch ingress AXI4-Stream master, 128-bit, clk domain
  // (-> ingress_port_wr.sv s_axis_*)
  output logic [127:0] m_axis_tdata,
  output logic [15:0] m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,
  input  logic         m_axis_tready,

  // switch egress AXI4-Stream slave, 128-bit, clk domain
  // (<- egress_port_rd.sv m_axis_*)
  input  logic [127:0] s_axis_tdata,
  input  logic [15:0] s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // AXI4-Lite register access, axis_clk domain
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

  output wire rx_bitslip_o,
  output wire rx_reset_req_o,
  output logic interrupt,
  output logic mac_irq
);


  wire [63:0] xgmii_txd, xgmii_rxd;
  wire [7:0] xgmii_txc, xgmii_rxc;
  wire block_lock, high_ber, rx_status, rx_bad_block, rx_sequence_error, tx_bad_block;
  wire [6:0] rx_error_count;
  eth_phy_10g #(.BIT_REVERSE(1),.COUNT_125US(RX_HEALTH_WINDOW)) pcs (
    .tx_clk(gtx_clk),.tx_rst(!gtx_rst_n),.rx_clk(gth_clk),.rx_rst(!gth_rst_n),
    .xgmii_txd(xgmii_txd),.xgmii_txc(xgmii_txc),.xgmii_rxd(xgmii_rxd),.xgmii_rxc(xgmii_rxc),
    .serdes_tx_data(txdata_o),.serdes_tx_hdr(txcharisk_o),
    .serdes_rx_data(rxdata_i),.serdes_rx_hdr(rxcharisk_i),
    .serdes_rx_bitslip(rx_bitslip_o),.serdes_rx_reset_req(rx_reset_req_o),
    .tx_bad_block(tx_bad_block),.rx_error_count(rx_error_count),.rx_bad_block(rx_bad_block),
    .rx_sequence_error(rx_sequence_error),.rx_block_lock(block_lock),.rx_high_ber(high_ber),.rx_status(rx_status),
    .cfg_tx_prbs31_enable(1'b0),.cfg_rx_prbs31_enable(1'b0));
  assign sync_ok_o=block_lock;
  wire [63:0] mac_txd;
  wire [7:0] mac_txc;
  wire tx_permit;
  sfp_10g_fault fault_control (
    .rx_clk(gth_clk),.rx_rst_n(gth_rst_n),.tx_clk(gtx_clk),.tx_rst_n(gtx_rst_n),
    .phy_ready(rx_status && !high_ber),.rxd(xgmii_rxd),.rxc(xgmii_rxc),
    .mac_txd(mac_txd),.mac_txc(mac_txc),.txd(xgmii_txd),.txc(xgmii_txc),
    .link_up(an_link_up_o),.remote_fault(an_remote_fault_o),.tx_permit(tx_permit));
  assign an_duplex_full_o=1;
  assign an_pause_o=0;

  assign interrupt=0;
  assign mac_irq=0;

  // Management registers keep the RX/TX enable offsets used by links.c.
  // All AW/W beats are captured independently; responses hold under stalls.
  reg [17:0] awaddr;
  reg [31:0] wdata;
  reg [3:0] wstrb;
  reg awfull,wfull;
  reg rx_enable,tx_enable;
  (* ASYNC_REG="TRUE" *) reg [1:0] rx_en_sync,tx_en_sync;
  (* ASYNC_REG="TRUE" *) reg [2:0] status_meta,status_sync;
  always @(posedge gth_clk) begin
    if (!gth_rst_n) rx_en_sync<=0; else rx_en_sync<={rx_en_sync[0],rx_enable};
  end
  always @(posedge gtx_clk) begin
    if (!gtx_rst_n) tx_en_sync<=0; else tx_en_sync<={tx_en_sync[0],tx_enable};
  end
  always @(posedge axis_clk) begin
    if (!axis_rst_n) begin status_meta<=0;status_sync<=0;end
    else begin status_meta<={high_ber,rx_status,block_lock};status_sync<=status_meta;end
  end
  assign s_axi_awready=!awfull && !s_axi_bvalid;
  assign s_axi_wready=!wfull && !s_axi_bvalid;
  assign s_axi_arready=!s_axi_rvalid;
  assign s_axi_bresp=0;
  assign s_axi_rresp=0;
  always @(posedge axis_clk) begin
    if (!axis_rst_n) begin
      awfull<=0;wfull<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_rdata<=0;
      rx_enable<=DEFAULT_ENABLE;tx_enable<=DEFAULT_ENABLE;awaddr<=0;wdata<=0;wstrb<=0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr;awfull<=1;end
      if (s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;wfull<=1;end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
      if (awfull && wfull && !s_axi_bvalid) begin
        if (awaddr==18'h404 && wstrb[3]) rx_enable<=wdata[28];
        if (awaddr==18'h408 && wstrb[3]) tx_enable<=wdata[28];
        awfull<=0;wfull<=0;s_axi_bvalid<=1;
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid<=1;
        case(s_axi_araddr)
          18'h404: s_axi_rdata<={3'b0,rx_enable,28'b0};
          18'h408: s_axi_rdata<={3'b0,tx_enable,28'b0};
          18'h4f0: s_axi_rdata<=10000; // host rate; copper rate is module-specific
          18'h4f4: s_axi_rdata<={29'b0,status_sync};
          18'h4f8: s_axi_rdata<=32'h31304745; // distinct 10GE core ID
          18'h4fc: s_axi_rdata<=1;
          default: s_axi_rdata<=0;
        endcase
      end
    end
  end
  wire tx_underflow,tx_overflow,tx_bad,tx_good,rx_bad,rx_fcs,rx_overflow,rx_fifo_bad,rx_good;
  eth_mac_10g_fifo #(.AXIS_DATA_WIDTH(128),.AXIS_KEEP_WIDTH(16),
    .TX_FIFO_DEPTH(16384),.RX_FIFO_DEPTH(16384)) mac (
    .rx_clk(gth_clk),.rx_rst(!gth_rst_n),.tx_clk(gtx_clk),.tx_rst(!gtx_rst_n),
    .logic_clk(clk),.logic_rst(!rst_n),.ptp_sample_clk(1'b0),
    .tx_axis_tdata(s_axis_tdata),.tx_axis_tkeep(s_axis_tkeep),.tx_axis_tvalid(s_axis_tvalid),
    .tx_axis_tready(s_axis_tready),.tx_axis_tlast(s_axis_tlast),.tx_axis_tuser(1'b0),
    .rx_axis_tdata(m_axis_tdata),.rx_axis_tkeep(m_axis_tkeep),.rx_axis_tvalid(m_axis_tvalid),
    .rx_axis_tready(m_axis_tready),.rx_axis_tlast(m_axis_tlast),.rx_axis_tuser(m_axis_tuser),
    .xgmii_txd(mac_txd),.xgmii_txc(mac_txc),.xgmii_rxd(xgmii_rxd),.xgmii_rxc(xgmii_rxc),
    .tx_error_underflow(tx_underflow),.tx_fifo_overflow(tx_overflow),.tx_fifo_bad_frame(tx_bad),.tx_fifo_good_frame(tx_good),
    .rx_error_bad_frame(rx_bad),.rx_error_bad_fcs(rx_fcs),.rx_fifo_overflow(rx_overflow),
    .rx_fifo_bad_frame(rx_fifo_bad),.rx_fifo_good_frame(rx_good),
    .m_axis_tx_ptp_ts_96(),.m_axis_tx_ptp_ts_tag(),.m_axis_tx_ptp_ts_valid(),.m_axis_tx_ptp_ts_ready(1'b1),
    .ptp_ts_96(96'b0),.ptp_ts_step(1'b0),.cfg_ifg(8'd12),
    .cfg_tx_enable(tx_en_sync[1] && tx_permit),.cfg_rx_enable(rx_en_sync[1] && an_link_up_o));
  // Packet/byte counters at the fabric handoff. Error events add dropped frames;
  // exact byte counts for frames discarded inside the MAC are unavailable.
  wire [3:0][31:0] rx_inc,tx_inc;
  wire [7:0][31:0] inc;
  stats_axis #(.KEEP_WIDTH(16)) rx_stats (.clk(clk),.rst_n(rst_n),
    .valid(m_axis_tvalid),.ready(m_axis_tready),.last(m_axis_tlast),.bad(m_axis_tuser),.keep(m_axis_tkeep),.increment(rx_inc));
  stats_axis #(.KEEP_WIDTH(16)) tx_stats (.clk(clk),.rst_n(rst_n),
    .valid(s_axis_tvalid),.ready(s_axis_tready),.last(s_axis_tlast),.bad(1'b0),.keep(s_axis_tkeep),.increment(tx_inc));
  assign inc[0]=rx_inc[0]; assign inc[1]=rx_inc[1]+32'(rx_fifo_bad || rx_overflow);
  assign inc[2]=rx_inc[2]; assign inc[3]=rx_inc[3];
  assign inc[4]=tx_inc[0]; assign inc[5]=tx_inc[1]+32'(tx_underflow || tx_overflow || tx_bad);
  assign inc[6]=tx_inc[2]; assign inc[7]=tx_inc[3];
  stats_bank port_statistics (.clk(clk),.rst_n(rst_n),.increment(inc),
    .request(stats_request),.select(stats_select),.activity(stats_activity),.ack(stats_ack),.value(stats_value));
endmodule
