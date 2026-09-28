// Single physical channel X0Y6. Clock dividers/muxes change only under reset.
module gth_sfp_dual_wrapper (
 input wire freerun_clk_i,rst_n,gtrefclk_p_i,gtrefclk_n_i,
 input wire rxp_i,rxn_i,output wire txp_o,txn_o,
 input wire request_10g_i,retry_toggle_i,
 output wire mode_10g_o,ready_o,error_o,
 input wire [63:0] txdata_i,input wire [1:0] txcharisk_i,
 output wire [63:0] rxdata_o,output wire [1:0] rxcharisk_o,rxdisperr_o,rxnotintable_o,
 input wire rx_bitslip_i,rx_reset_req_i,
 output wire tx_clk_o,tx_rst_n_o,rx_clk_o,rx_rst_n_o,
 output wire gmii_clk_o,gmii_rst_n_o,pcs1g_clk_o,pcs1g_rst_n_o,
 output wire gtpowergood_o,tx_resetdone_o,rx_resetdone_o,locked_o
);
 wire refclk;
 IBUFDS_GTE4 refbuf(.I(gtrefclk_p_i),.IB(gtrefclk_n_i),.CEB(1'b0),.O(refclk),.ODIV2());
 (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,retry_sync;
 (* ASYNC_REG="TRUE" *) reg [4:0] done_meta,done_sync;
 wire lock0,lock1,gt_reset;
 always @(posedge freerun_clk_i) begin
   if(!rst_n) begin req_sync<=3;retry_sync<=0;done_meta<=0;done_sync<=0;end
   else begin
     req_sync<={req_sync[0],request_10g_i};retry_sync<={retry_sync[0],retry_toggle_i};
     done_meta<={gtpowergood_o,lock0,lock1,tx_resetdone_o,rx_resetdone_o};done_sync<=done_meta;
   end
 end
 wire [9:0] da;wire [15:0] di,dout;wire den,dwe,drdy;
 sfp_dual_reconfigure control(.clk(freerun_clk_i),.rst_n(rst_n),
  .request_10g(req_sync[1]),.retry_toggle(retry_sync[1]),
  .power_good(done_sync[4]),.pll_locked(done_sync[3] && done_sync[2]),.tx_done(done_sync[1]),.rx_done(done_sync[0]),
  .mode_10g(mode_10g_o),.ready(ready_o),.error(error_o),.gt_reset(gt_reset),
  .drp_addr(da),.drp_di(di),.drp_en(den),.drp_we(dwe),.drp_do(dout),.drp_rdy(drdy));
 wire txout,rxout,txusr,rxusr,rxusr2,txpma,rxpma;
 wire txclear=gt_reset || !txpma,rxclear=gt_reset || !rxpma;
 BUFG_GT txfast(.I(txout),.CE(1'b1),.CEMASK(1'b0),.CLR(txclear),.CLRMASK(1'b0),.DIV(3'b000),.O(txusr));
 BUFG_GT txslow(.I(txout),.CE(1'b1),.CEMASK(1'b0),.CLR(txclear),.CLRMASK(1'b0),.DIV({2'b0,mode_10g_o}),.O(tx_clk_o));
 BUFG_GT rxfast(.I(rxout),.CE(1'b1),.CEMASK(1'b0),.CLR(rxclear),.CLRMASK(1'b0),.DIV(3'b000),.O(rxusr));
 BUFG_GT rxslow(.I(rxout),.CE(1'b1),.CEMASK(1'b0),.CLR(rxclear),.CLRMASK(1'b0),.DIV({2'b0,mode_10g_o}),.O(rxusr2));
 // 1G elastic buffer uses the local TX clock, as in the fixed 1G build.
 wire rxuserclock;
 BUFGMUX_CTRL rxselect(.I0(txusr),.I1(rxusr),.S(mode_10g_o),.O(rxuserclock));
 BUFGMUX_CTRL rxselect2(.I0(tx_clk_o),.I1(rxusr2),.S(mode_10g_o),.O(rx_clk_o));
 reg [3:0] tx_active,rx_active;
 always @(posedge tx_clk_o or posedge txclear)
  if(txclear) tx_active<=0;else tx_active<={tx_active[2:0],1'b1};
 always @(posedge rx_clk_o or posedge rxclear)
  if(rxclear) rx_active<=0;else rx_active<={rx_active[2:0],1'b1};
 reg watchdog_toggle;
 always @(posedge rx_clk_o or negedge rst_n)
  if(!rst_n) watchdog_toggle<=0;else if(mode_10g_o && rx_reset_req_i) watchdog_toggle<=!watchdog_toggle;
 (* ASYNC_REG="TRUE" *) reg [1:0] wd_sync;
 reg wd_seen;reg [4:0] wd_hold;
 always @(posedge freerun_clk_i) begin
  if(!rst_n || gt_reset) begin wd_sync<=0;wd_seen<=0;wd_hold<=0;end
  else begin
   wd_sync<={wd_sync[0],watchdog_toggle};wd_seen<=wd_sync[1];
   if(wd_seen!=wd_sync[1]) wd_hold<=16;else if(wd_hold!=0) wd_hold<=wd_hold-1'b1;
  end
 end
 wire [15:0] rc0,rc1;wire [7:0] rc3;wire [5:0] header;
 gth_sfp_dual_ip u_gt(
 .gtwiz_userclk_tx_active_in(tx_active[3]),.gtwiz_userclk_rx_active_in(rx_active[3]),
 .gtwiz_reset_clk_freerun_in(freerun_clk_i),.gtwiz_reset_all_in(!rst_n || gt_reset),
 .gtwiz_reset_tx_pll_and_datapath_in(1'b0),.gtwiz_reset_tx_datapath_in(1'b0),
 .gtwiz_reset_rx_pll_and_datapath_in(1'b0),.gtwiz_reset_rx_datapath_in(wd_hold!=0),
 .gtwiz_reset_rx_cdr_stable_out(),.gtwiz_reset_tx_done_out(tx_resetdone_o),.gtwiz_reset_rx_done_out(rx_resetdone_o),
 .gtrefclk00_in(refclk),.gtrefclk01_in(refclk),.qpll0lock_out(lock0),.qpll1lock_out(lock1),.qpll1reset_in(!rst_n || gt_reset),
 .qpll0outclk_out(),.qpll0outrefclk_out(),
 .drpaddr_in(da),.drpclk_in(freerun_clk_i),.drpdi_in(di),.drpen_in(den),.drpwe_in(dwe),.drpdo_out(dout),.drprdy_out(drdy),
 .gthrxn_in(rxn_i),.gthrxp_in(rxp_i),.gthtxn_out(txn_o),.gthtxp_out(txp_o),.gtpowergood_out(gtpowergood_o),
 .rx8b10ben_in(!mode_10g_o),.rxcommadeten_in(!mode_10g_o),.rxmcommaalignen_in(!mode_10g_o),.rxpcommaalignen_in(!mode_10g_o),
 .rxlpmen_in(!mode_10g_o),.rxgearboxslip_in(mode_10g_o && rx_bitslip_i),
 .rxoutclksel_in(mode_10g_o?3'b101:3'b010),.txoutclksel_in(mode_10g_o?3'b101:3'b010),
 .rxpllclksel_in(mode_10g_o?2'b11:2'b10),.txpllclksel_in(mode_10g_o?2'b11:2'b10),
 .rxsysclksel_in(mode_10g_o?2'b10:2'b11),.txsysclksel_in(mode_10g_o?2'b10:2'b11),
 .rxusrclk_in(rxuserclock),.rxusrclk2_in(rx_clk_o),.txusrclk_in(txusr),.txusrclk2_in(tx_clk_o),
 .tx8b10ben_in(!mode_10g_o),.txctrl0_in(16'b0),.txctrl1_in(16'b0),.txctrl2_in(mode_10g_o?8'b0:{6'b0,txcharisk_i}),
 .txheader_in(mode_10g_o?{4'b0,txcharisk_i}:6'b0),.txsequence_in(7'b0),
 .gtwiz_userdata_tx_in(txdata_i),.gtwiz_userdata_rx_out(rxdata_o),
 .rxctrl0_out(rc0),.rxctrl1_out(rc1),.rxctrl2_out(),.rxctrl3_out(rc3),.rxheader_out(header),
 .rxdatavalid_out(),.rxheadervalid_out(),.rxstartofseq_out(),
 .rxoutclk_out(rxout),.txoutclk_out(txout),.rxpmaresetdone_out(rxpma),.txpmaresetdone_out(txpma),
 .rxprgdivresetdone_out(),.txprgdivresetdone_out());
 assign rxcharisk_o=mode_10g_o?header[1:0]:rc0[1:0];
 assign rxdisperr_o=mode_10g_o?2'b0:rc1[1:0];
 assign rxnotintable_o=mode_10g_o?2'b0:rc3[1:0];
 wire mmcm_locked;
 sfp_pcs_clk_gen u_1g_clocks(.gth_clk_i(tx_clk_o),.gth_rst_n_i(ready_o && !mode_10g_o),
  .gtx_clk_o(gmii_clk_o),.gtx_rst_n_o(gmii_rst_n_o),.gth_clk_o(pcs1g_clk_o),.gth_rst_n_o(pcs1g_rst_n_o),.locked_o(mmcm_locked));
 rst_sync tx_reset(.clk(tx_clk_o),.arst_n_i(rst_n && ready_o && mode_10g_o),.rst_n_o(tx_rst_n_o));
 rst_sync rx_reset(.clk(rx_clk_o),.arst_n_i(rst_n && ready_o && mode_10g_o),.rst_n_o(rx_rst_n_o));
 assign locked_o=ready_o && (mode_10g_o || mmcm_locked);
endmodule
