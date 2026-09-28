`timescale 1ns/1ps
// Vivado/XSim only: actual GTHE4 simulation models and generated Wizard core.
module tb_sfp_dual_gth;
 reg clk=0,refclk=0,rst_n=0,request=1,retry=0;
 always #10 clk=~clk;
 always #3.2 refclk=~refclk;
 wire txp,txn,mode,ready,error,txclk,rxclk,txrst,rxrst,gmii,gmii_rst,pcs,pcs_rst;
 wire [63:0] rxd;wire [1:0] rxc,disparity,notintable;
 reg slip=0;reg [4:0] slip_wait=0;
 always @(posedge rxclk) begin
  slip<=0;
  if(!mode || !rxrst) slip_wait<=0;
  else if(slip_wait!=0) slip_wait<=slip_wait-1'b1;
  else if(rxc!=2'b01 || rxd!=64'h1e1e1e1e1e1e1e1e) begin slip<=1;slip_wait<=31;end
 end
 gth_sfp_dual_wrapper dut(.freerun_clk_i(clk),.rst_n(rst_n),.gtrefclk_p_i(refclk),.gtrefclk_n_i(!refclk),
  .rxp_i(txp),.rxn_i(txn),.txp_o(txp),.txn_o(txn),.request_10g_i(request),.retry_toggle_i(retry),
  .mode_10g_o(mode),.ready_o(ready),.error_o(error),
  .txdata_i(mode?64'h1e1e1e1e1e1e1e1e:64'h00000000000050bc),.txcharisk_i(2'b01),
  .rxdata_o(rxd),.rxcharisk_o(rxc),.rxdisperr_o(disparity),.rxnotintable_o(notintable),.rx_bitslip_i(slip),.rx_reset_req_i(1'b0),
  .tx_clk_o(txclk),.tx_rst_n_o(txrst),.rx_clk_o(rxclk),.rx_rst_n_o(rxrst),
  .gmii_clk_o(gmii),.gmii_rst_n_o(gmii_rst),.pcs1g_clk_o(pcs),.pcs1g_rst_n_o(pcs_rst),
  .gtpowergood_o(),.tx_resetdone_o(),.rx_resetdone_o(),.locked_o());
 task check_period(input bit ten);
  realtime start_t,period_t;
  begin
   repeat(20) @(posedge txclk);start_t=$realtime;repeat(100) @(posedge txclk);period_t=($realtime-start_t)/100;
   if(ten ? (period_t<6.39 || period_t>6.41):(period_t<15.99 || period_t>16.01))
    $fatal(1,"TX clock rate incorrect mode=%0d period=%f",ten,period_t);
   repeat(20) @(posedge rxclk);start_t=$realtime;repeat(100) @(posedge rxclk);period_t=($realtime-start_t)/100;
   if(ten ? (period_t<6.39 || period_t>6.41):(period_t<15.99 || period_t>16.01))
    $fatal(1,"RX clock rate incorrect mode=%0d period=%f",ten,period_t);
   if(!ten) begin
    wait(gmii_rst && pcs_rst);
    @(posedge gmii);start_t=$realtime;repeat(100) @(posedge gmii);period_t=($realtime-start_t)/100;
    if(period_t<7.99 || period_t>8.01) $fatal(1,"1G GMII clock incorrect %f",period_t);
   end
   repeat(4096) @(posedge rxclk);
   repeat(100) begin
    @(posedge rxclk);
    if(ten) begin
     if(rxc!==2'b01 || rxd!==64'h1e1e1e1e1e1e1e1e) $fatal(1,"10G serial loopback/header mismatch %h %b",rxd,rxc);
    end else if(disparity || notintable || !((rxd[15:0]==16'h50bc && rxc==1) || (rxd[15:0]==16'hbc50 && rxc==2)))
     $fatal(1,"1G 8b10b serial loopback mismatch %h K=%b err=%b%b",rxd,rxc,disparity,notintable);
   end
   $display("GT MODE %0d clock checks pass at %t",ten,$time);
  end
 endtask
 initial begin
  #1000;rst_n=1;wait(ready);check_period(1);
  @(negedge clk);request=0;retry=!retry;wait(!ready);wait(ready);check_period(0);
  @(negedge clk);request=1;retry=!retry;wait(!ready);wait(ready);check_period(1);
  $display("PASS: GTHE4 DRP readback, PLL/reset completion, runtime 10G/1G/10G clock rates and serial data/8b10b/header integrity");$finish;
 end
 initial forever begin #10000;$display("GTH progress t=%t state=%0d power=%b locks=%b%b done=%b%b",$time,dut.control.state,dut.gtpowergood_o,dut.lock0,dut.lock1,dut.tx_resetdone_o,dut.rx_resetdone_o);end
 always @(posedge clk) if(error) $fatal(1,"GTH reconfiguration error state=%0d addr=%h",dut.control.state,dut.da);
 initial begin #500000;$fatal(1,"GTH simulation timeout state=%0d addr=%h power=%b locks=%b%b done=%b%b",dut.control.state,dut.da,dut.gtpowergood_o,dut.lock0,dut.lock1,dut.tx_resetdone_o,dut.rx_resetdone_o);end
endmodule
