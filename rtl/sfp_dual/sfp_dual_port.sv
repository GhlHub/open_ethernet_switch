// Runtime-selectable 1000BASE-X / 10GBASE-R digital port.
module sfp_dual_port #(parameter int RX_HEALTH_WINDOW=19531,
 parameter int AN_BREAK_LINK_CYCLES=1250000, AN_LINK_TIMER_CYCLES=1250000, AN_IDLE_DETECT_CYCLES=1250000) (
  input wire gmii_clk,gmii_rst_n,pcs1g_clk,pcs1g_rst_n,
  input wire gt_mode_10g_i,gt_ready_i,gt_error_i,
  output reg gt_request_10g_o,gt_retry_o,
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


 // Control is always clocked, including while the physical clocks are stopped.
 reg [17:0] awaddr;reg [31:0] wdata;reg [3:0] wstrb;
 reg awfull,wfull,rx_enable,tx_enable,request_mode,request_toggle;
 (* ASYNC_REG="TRUE" *) reg [5:0] status_meta,status_sync;
 wire running;
 reg running_status;
 always @(posedge clk) begin
  if(!rst_n) running_status<=0;else running_status<=running;
 end
 always @(posedge axis_clk) begin
  if(!axis_rst_n) begin status_meta<=0;status_sync<=0;end
  else begin status_meta<={an_remote_fault_o,an_link_up_o,running_status,gt_error_i,gt_ready_i,gt_mode_10g_i};status_sync<=status_meta;end
 end
 assign s_axi_awready=!awfull && !s_axi_bvalid;
 assign s_axi_wready=!wfull && !s_axi_bvalid;
 assign s_axi_arready=!s_axi_rvalid;
 assign s_axi_bresp=0;assign s_axi_rresp=0;assign interrupt=0;assign mac_irq=0;
 always @(posedge axis_clk) begin
  if(!axis_rst_n) begin
   awfull<=0;wfull<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_rdata<=0;
   awaddr<=0;wdata<=0;wstrb<=0;rx_enable<=0;tx_enable<=0;request_mode<=1;request_toggle<=0;
  end else begin
   if(s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr;awfull<=1;end
   if(s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;wfull<=1;end
   if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
   if(awfull && wfull && !s_axi_bvalid) begin
    if(awaddr==18'h404 && wstrb[3]) rx_enable<=wdata[28];
    if(awaddr==18'h408 && wstrb[3]) tx_enable<=wdata[28];
    // Each write requests a reinitialization, even when selecting the same rate.
    if(awaddr==18'h4e0 && wstrb[0]) begin request_mode<=wdata[0];request_toggle<=!request_toggle;end
    awfull<=0;wfull<=0;s_axi_bvalid<=1;
   end
   if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
   if(s_axi_arvalid && s_axi_arready) begin
    s_axi_rvalid<=1;
    case(s_axi_araddr)
     18'h404:s_axi_rdata<={3'b0,rx_enable,28'b0};
     18'h408:s_axi_rdata<={3'b0,tx_enable,28'b0};
     18'h4e0:s_axi_rdata<={31'b0,request_mode};
     18'h4e4:s_axi_rdata<={26'b0,status_sync};
     18'h4ec:s_axi_rdata<=3; // bit 0: 1G supported; bit 1: 10G supported
     18'h4f0:s_axi_rdata<=status_sync[0]?10000:1000;
     18'h4f4:s_axi_rdata<={26'b0,status_sync};
     18'h4f8:s_axi_rdata<=32'h4455414c; // DUAL
     18'h4fc:s_axi_rdata<=1;
     default:s_axi_rdata<=0;
    endcase
   end
  end
 end
 (* ASYNC_REG="TRUE" *) reg [1:0] mode_sync,toggle_sync,ready_sync,actual_sync,rxen_sync,txen_sync;
 always @(posedge clk) begin
  if(!rst_n) begin mode_sync<=3;toggle_sync<=0;ready_sync<=0;actual_sync<=3;rxen_sync<=0;txen_sync<=0;end
  else begin
   mode_sync<={mode_sync[0],request_mode};toggle_sync<={toggle_sync[0],request_toggle};
   ready_sync<={ready_sync[0],gt_ready_i};actual_sync<={actual_sync[0],gt_mode_10g_i};
   rxen_sync<={rxen_sync[0],rx_enable};txen_sync<={txen_sync[0],tx_enable};
  end
 end
 localparam WAIT_LOW=0,WAIT_HIGH=1,RUN=2,QUIET=3,RESET=4;
 reg [2:0] state;reg [5:0] settle;reg sent_toggle,active_mode;
 wire streams_idle;
 assign running=(state==RUN && ready_sync[1]);
 wire run_paths=(state==RUN || state==QUIET) && ready_sync[1];
 always @(posedge clk) begin
  if(!rst_n) begin
   // The GTH can already be ready when the fabric clock/reset starts.
   // Only subsequent commands require observing its ready-low handshake.
   state<=WAIT_HIGH;settle<=0;sent_toggle<=0;active_mode<=1;
   gt_request_10g_o<=1;gt_retry_o<=0;
  end else begin
   case(state)
    WAIT_LOW: if(!ready_sync[1]) begin state<=WAIT_HIGH;settle<=0;end
    WAIT_HIGH: if(toggle_sync[1]!=sent_toggle || mode_sync[1]!=gt_request_10g_o) begin
       // A failed or stopped GT must still accept a retry/new mode. Waiting
       // for ready before forwarding this command would deadlock recovery.
       state<=RESET;settle<=0;
      end else if(ready_sync[1] && actual_sync[1]==gt_request_10g_o) begin
       if(settle==31) begin active_mode<=actual_sync[1];state<=RUN;end else settle<=settle+1'b1;
      end else settle<=0;
    RUN: if(toggle_sync[1]!=sent_toggle || mode_sync[1]!=gt_request_10g_o) state<=QUIET;
         else if(!ready_sync[1]) begin state<=WAIT_HIGH;settle<=0;end
    QUIET: if(streams_idle) begin state<=RESET;settle<=0;end
    RESET: if(settle==31) begin
       gt_request_10g_o<=mode_sync[1];gt_retry_o<=!gt_retry_o;
       sent_toggle<=toggle_sync[1];state<=WAIT_LOW;
      end else settle<=settle+1'b1;
    default:state<=WAIT_LOW;
   endcase
  end
 end
 wire reset1_f,reset10_f,reset1_a,reset10_a;
 wire reset1_gmii,reset1_pcs,reset10_tx,reset10_rx;
 rst_sync r1g(.clk(gmii_clk),.arst_n_i(gmii_rst_n && run_paths && !active_mode),.rst_n_o(reset1_gmii));
 rst_sync r1p(.clk(pcs1g_clk),.arst_n_i(pcs1g_rst_n && run_paths && !active_mode),.rst_n_o(reset1_pcs));
 rst_sync r10t(.clk(gtx_clk),.arst_n_i(gtx_rst_n && run_paths && active_mode),.rst_n_o(reset10_tx));
 rst_sync r10r(.clk(gth_clk),.arst_n_i(gth_rst_n && run_paths && active_mode),.rst_n_o(reset10_rx));
 rst_sync r1f(.clk(clk),.arst_n_i(rst_n && run_paths && !active_mode),.rst_n_o(reset1_f));
 rst_sync r10f(.clk(clk),.arst_n_i(rst_n && run_paths && active_mode),.rst_n_o(reset10_f));
 rst_sync r1a(.clk(axis_clk),.arst_n_i(axis_rst_n && run_paths && !active_mode),.rst_n_o(reset1_a));
 rst_sync r10a(.clk(axis_clk),.arst_n_i(axis_rst_n && run_paths && active_mode),.rst_n_o(reset10_a));
 wire [127:0] rxd1,rxd10;wire [15:0] rxk1,rxk10;
 wire rxv1,rxv10,rxl1,rxl10,rxu1,rxu10,rxr1,rxr10,txr1,txr10;
 wire [15:0] narrow_rxd,narrow_txd;wire [1:0] narrow_rxk,narrow_txk;
 wire narrow_rxv,narrow_rxl,narrow_rxu,narrow_rxr,narrow_txv,narrow_txl,narrow_txr;
 wire admit_tx,selected_rx_ready;
 sfp_dual_stream_gate gate(.clk(clk),.rst_n(rst_n),.run(run_paths),.allow_new(state==RUN),
  .tx_enable(txen_sync[1] && an_link_up_o),.rx_enable(rxen_sync[1] && an_link_up_o),
  .s_tx_data(s_axis_tdata),.s_tx_keep(s_axis_tkeep),.s_tx_valid(s_axis_tvalid),.s_tx_last(s_axis_tlast),.s_tx_ready(s_axis_tready),
  .m_tx_data(),.m_tx_keep(),.m_tx_valid(admit_tx),.m_tx_last(),.m_tx_ready(active_mode?txr10:txr1),
  .s_rx_data(active_mode?rxd10:rxd1),.s_rx_keep(active_mode?rxk10:rxk1),
  .s_rx_valid(active_mode?rxv10:rxv1),.s_rx_last(active_mode?rxl10:rxl1),.s_rx_user(active_mode?rxu10:rxu1),.s_rx_ready(selected_rx_ready),
  .m_rx_data(m_axis_tdata),.m_rx_keep(m_axis_tkeep),.m_rx_valid(m_axis_tvalid),.m_rx_last(m_axis_tlast),.m_rx_user(m_axis_tuser),.m_rx_ready(m_axis_tready),.idle(streams_idle));
 assign rxr1=active_mode?1'b1:selected_rx_ready;
 assign rxr10=active_mode?selected_rx_ready:1'b1;
 axis_adapter #(.S_DATA_WIDTH(16),.S_KEEP_WIDTH(2),.M_DATA_WIDTH(128),.M_KEEP_WIDTH(16)) rx_width(
  .clk(clk),.rst(!reset1_f),.s_axis_tdata(narrow_rxd),.s_axis_tkeep(narrow_rxk),.s_axis_tvalid(narrow_rxv),.s_axis_tready(narrow_rxr),
  .s_axis_tlast(narrow_rxl),.s_axis_tuser(narrow_rxu),.s_axis_tid(8'b0),.s_axis_tdest(8'b0),
  .m_axis_tdata(rxd1),.m_axis_tkeep(rxk1),.m_axis_tvalid(rxv1),.m_axis_tready(rxr1),.m_axis_tlast(rxl1),.m_axis_tuser(rxu1),.m_axis_tid(),.m_axis_tdest());
 axis_adapter #(.S_DATA_WIDTH(128),.S_KEEP_WIDTH(16),.M_DATA_WIDTH(16),.M_KEEP_WIDTH(2)) tx_width(
  .clk(clk),.rst(!reset1_f),.s_axis_tdata(s_axis_tdata),.s_axis_tkeep(s_axis_tkeep),.s_axis_tvalid(s_axis_tvalid && admit_tx && !active_mode),.s_axis_tready(txr1),
  .s_axis_tlast(s_axis_tlast),.s_axis_tuser(1'b0),.s_axis_tid(8'b0),.s_axis_tdest(8'b0),
  .m_axis_tdata(narrow_txd),.m_axis_tkeep(narrow_txk),.m_axis_tvalid(narrow_txv),.m_axis_tready(narrow_txr),.m_axis_tlast(narrow_txl),.m_axis_tuser(),.m_axis_tid(),.m_axis_tdest());
 wire [15:0] txd1;wire [63:0] txd10;wire [1:0] txc1,txc10;
 wire sync1,sync10,link1,link10,duplex1,duplex10,fault1,fault10;wire [1:0] pause1,pause10;
 assign txdata_o=gt_mode_10g_i?txd10:{48'b0,txd1};
 assign txcharisk_o=gt_mode_10g_i?txc10:txc1;
 // Status originates in unrelated PCS domains; register after synchronization.
 reg [3:0] status1_source;
 always @(posedge gmii_clk or negedge gmii_rst_n) begin
  if(!gmii_rst_n) status1_source<=0;
  else status1_source<={fault1,duplex1,link1,sync1};
 end
 (* ASYNC_REG="TRUE" *) reg [7:0] pcs_meta,pcs_sync;
 wire [3:0] selected_status=active_mode?pcs_sync[7:4]:pcs_sync[3:0];
 always @(posedge clk) begin
  if(!rst_n) begin pcs_meta<=0;pcs_sync<=0;sync_ok_o<=0;an_link_up_o<=0;an_remote_fault_o<=0;an_duplex_full_o<=0;end
  else begin
   pcs_meta<={fault10,duplex10,link10,sync10,status1_source};pcs_sync<=pcs_meta;
   sync_ok_o<=running && selected_status[0];
   an_link_up_o<=running && selected_status[1] && selected_status[2] && !selected_status[3];
   an_duplex_full_o<=running && selected_status[2];
   an_remote_fault_o<=running && selected_status[3];
  end
 end
 assign an_pause_o=0;
 sfp_port_top #(.DEFAULT_ENABLE(1),.AN_BREAK_LINK_CYCLES(AN_BREAK_LINK_CYCLES),.AN_LINK_TIMER_CYCLES(AN_LINK_TIMER_CYCLES),.AN_IDLE_DETECT_CYCLES(AN_IDLE_DETECT_CYCLES)) port1(
  .clk(clk),
  .rst_n(reset1_f),
  .axis_clk(axis_clk),
  .axis_rst_n(reset1_a),
  .gtx_clk(gmii_clk),
  .gtx_rst_n(reset1_gmii),
  .gth_clk(pcs1g_clk),
  .gth_rst_n(reset1_pcs),
  .clk_en(1'b1),
  .stats_request(1'b0),
  .stats_select(4'b0),
  .stats_activity(),
  .stats_ack(),
  .stats_value(),
  .txdata_o(txd1),
  .txcharisk_o(txc1),
  .rxdata_i(rxdata_i[15:0]),
  .rxcharisk_i(rxcharisk_i),
  .rxdisperr_i(rxdisperr_i),
  .rxnotintable_i(rxnotintable_i),
  .sync_ok_o(sync1),
  .an_link_up_o(link1),
  .an_duplex_full_o(duplex1),
  .an_remote_fault_o(fault1),
  .an_pause_o(pause1),
  .m_axis_tdata(narrow_rxd),
  .m_axis_tkeep(narrow_rxk),
  .m_axis_tvalid(narrow_rxv),
  .m_axis_tlast(narrow_rxl),
  .m_axis_tuser(narrow_rxu),
  .m_axis_tready(narrow_rxr),
  .s_axis_tdata(narrow_txd),
  .s_axis_tkeep(narrow_txk),
  .s_axis_tvalid(narrow_txv),
  .s_axis_tlast(narrow_txl),
  .s_axis_tready(narrow_txr),
  .s_axi_awaddr(18'b0),
  .s_axi_awvalid(1'b0),
  .s_axi_awready(),
  .s_axi_wdata(32'b0),
  .s_axi_wstrb(4'b0),
  .s_axi_wvalid(1'b0),
  .s_axi_wready(),
  .s_axi_bresp(),
  .s_axi_bvalid(),
  .s_axi_bready(1'b1),
  .s_axi_araddr(18'b0),
  .s_axi_arvalid(1'b0),
  .s_axi_arready(),
  .s_axi_rdata(),
  .s_axi_rresp(),
  .s_axi_rvalid(),
  .s_axi_rready(1'b1),
  .interrupt(),
  .mac_irq());
 sfp_10g_port #(.DEFAULT_ENABLE(1),.RX_HEALTH_WINDOW(RX_HEALTH_WINDOW)) port10(
  .clk(clk),
  .rst_n(reset10_f),
  .axis_clk(axis_clk),
  .axis_rst_n(reset10_a),
  .gtx_clk(gtx_clk),
  .gtx_rst_n(reset10_tx),
  .gth_clk(gth_clk),
  .gth_rst_n(reset10_rx),
  .clk_en(1'b1),
  .stats_request(1'b0),
  .stats_select(4'b0),
  .stats_activity(),
  .stats_ack(),
  .stats_value(),
  .txdata_o(txd10),
  .txcharisk_o(txc10),
  .rxdata_i(rxdata_i),
  .rxcharisk_i(rxcharisk_i),
  .rxdisperr_i(rxdisperr_i),
  .rxnotintable_i(rxnotintable_i),
  .sync_ok_o(sync10),
  .an_link_up_o(link10),
  .an_duplex_full_o(duplex10),
  .an_remote_fault_o(fault10),
  .an_pause_o(pause10),
  .m_axis_tdata(rxd10),
  .m_axis_tkeep(rxk10),
  .m_axis_tvalid(rxv10),
  .m_axis_tlast(rxl10),
  .m_axis_tuser(rxu10),
  .m_axis_tready(rxr10),
  .s_axis_tdata(s_axis_tdata),
  .s_axis_tkeep(s_axis_tkeep),
  .s_axis_tvalid(s_axis_tvalid && admit_tx && active_mode),
  .s_axis_tlast(s_axis_tlast),
  .s_axis_tready(txr10),
  .s_axi_awaddr(18'b0),
  .s_axi_awvalid(1'b0),
  .s_axi_awready(),
  .s_axi_wdata(32'b0),
  .s_axi_wstrb(4'b0),
  .s_axi_wvalid(1'b0),
  .s_axi_wready(),
  .s_axi_bresp(),
  .s_axi_bvalid(),
  .s_axi_bready(1'b1),
  .s_axi_araddr(18'b0),
  .s_axi_arvalid(1'b0),
  .s_axi_arready(),
  .s_axi_rdata(),
  .s_axi_rresp(),
  .s_axi_rvalid(),
  .s_axi_rready(1'b1),
  .interrupt(),
  .mac_irq(),
  .rx_bitslip_o(rx_bitslip_o),
  .rx_reset_req_o(rx_reset_req_o));
 wire [3:0][31:0] rx_inc,tx_inc;
 wire [7:0][31:0] inc;
 stats_axis #(.KEEP_WIDTH(16)) rs(.clk(clk),.rst_n(rst_n),.valid(m_axis_tvalid),.ready(m_axis_tready),.last(m_axis_tlast),.bad(m_axis_tuser),.keep(m_axis_tkeep),.increment(rx_inc));
 stats_axis #(.KEEP_WIDTH(16)) ts(.clk(clk),.rst_n(rst_n),.valid(s_axis_tvalid && admit_tx),.ready(s_axis_tready),.last(s_axis_tlast),.bad(1'b0),.keep(s_axis_tkeep),.increment(tx_inc));
 assign inc={tx_inc,rx_inc};
 stats_bank stats(.clk(clk),.rst_n(rst_n),.increment(inc),.request(stats_request),.select(stats_select),.activity(stats_activity),.ack(stats_ack),.value(stats_value));
endmodule
