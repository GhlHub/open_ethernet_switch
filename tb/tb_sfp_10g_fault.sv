`timescale 1ns/1ps
module tb_sfp_10g_fault;
 reg rx_clk=0,tx_clk=0,rx_rst_n=0,tx_rst_n=0,phy_ready=0;
 reg run_rx=1;
 always #3.2 if(run_rx) rx_clk=~rx_clk; else rx_clk=0;
 always #3.201 tx_clk=~tx_clk;
 reg [63:0] rxd=64'h0707070707070707;
 reg [7:0] rxc=8'hff;
 wire [63:0] txd;
 wire [7:0] txc;
 wire link_up,remote_fault,tx_permit;
 sfp_10g_fault dut (.rx_clk(rx_clk),.tx_clk(tx_clk),.rx_rst_n(rx_rst_n),.tx_rst_n(tx_rst_n),.phy_ready(phy_ready),
 .rxd(rxd),.rxc(rxc),.mac_txd(64'h123456789abcdef0),.mac_txc(8'h00),.txd(txd),.txc(txc),.link_up(link_up),.remote_fault(remote_fault),.tx_permit(tx_permit));
 task settle;repeat(6) @(negedge tx_clk);endtask
 task idle;@(negedge rx_clk);rxd=64'h0707070707070707;rxc=8'hff;endtask
 task sequences(input [7:0] value,input integer n);
   for(integer i=0;i<n;i=i+1) begin
     @(negedge rx_clk);rxd={32'h07070707,value,24'h00009c};rxc=8'hf1;
     @(negedge rx_clk);rxd=64'h0707070707070707;rxc=8'hff;
   end
 endtask
 initial begin
 #100;rx_rst_n=1;tx_rst_n=1;settle();
 if(txd!==64'h0200009c0200009c || txc!=8'h11 || tx_permit) $fatal(1,"missing remote fault on PHY failure");
 phy_ready=1;settle();if(!link_up || !tx_permit || txd!==64'h123456789abcdef0) $fatal(1,"link did not start");
 sequences(2,3);if(remote_fault) $fatal(1,"fault qualified before four sequences");
 sequences(2,1);settle();if(!remote_fault || link_up || tx_permit || txd!==64'h0707070707070707) $fatal(1,"remote fault response");
 idle();repeat(70) @(negedge rx_clk);settle();if(!link_up || remote_fault || !tx_permit) $fatal(1,"remote fault did not clear");
 sequences(1,4);settle();if(link_up || tx_permit || txd!==64'h0200009c0200009c) $fatal(1,"local fault response");
 idle();repeat(70) @(negedge rx_clk);settle();if(!link_up) $fatal(1,"local fault did not clear");
 @(negedge rx_clk);run_rx=0;#10;rx_rst_n=0;#1;
 if(link_up || remote_fault) $fatal(1,"stopped RX clock retained link after reset");
 settle();if(tx_permit || txd!==64'h0200009c0200009c) $fatal(1,"stopped RX reset did not signal fault");
 rx_rst_n=1;run_rx=1;settle();if(!link_up || !tx_permit) $fatal(1,"RX restart failed");
 $display("PASS: XGMII fault qualification, responses and recovery with independent clocks");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
