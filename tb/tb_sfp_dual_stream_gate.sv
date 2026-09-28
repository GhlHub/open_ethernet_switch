`timescale 1ns/1ps
module tb_sfp_dual_stream_gate;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,run=1,allow_new=1,tx_enable=1,rx_enable=1;
 reg [127:0] tx=0,rx=0;reg tv=0,tl=0,tr=1,rv=0,rl=0,ru=0,rr=0;
 wire str,mv,ml,srr,ov,ol,ou,idle;wire [127:0] od;wire [15:0] ok;
 sfp_dual_stream_gate dut(.clk(clk),.rst_n(rst_n),.run(run),.allow_new(allow_new),.tx_enable(tx_enable),.rx_enable(rx_enable),
 .s_tx_data(tx),.s_tx_keep(16'hffff),.s_tx_valid(tv),.s_tx_last(tl),.s_tx_ready(str),.m_tx_data(),.m_tx_keep(),.m_tx_valid(mv),.m_tx_last(ml),.m_tx_ready(tr),
 .s_rx_data(rx),.s_rx_keep(16'hffff),.s_rx_valid(rv),.s_rx_last(rl),.s_rx_user(ru),.s_rx_ready(srr),.m_rx_data(od),.m_rx_keep(ok),.m_rx_valid(ov),.m_rx_last(ol),.m_rx_user(ou),.m_rx_ready(rr),.idle(idle));
 task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
 initial begin
  #20;@(negedge clk);rst_n=1;
  // RX beat stalled at output must survive a stopped/reset PHY.
  rx=128'h123456;rv=1;tick();rv=0;
  if(!ov || od!=rx || ol) $fatal(1,"RX skid missing");
  run=0;repeat(5) begin tick();if(!ov || od!=rx || ol || ou) $fatal(1,"stalled beat changed on link loss");end
  rr=1;tick();
  if(!ov || !ol || !ou || ok!=1) $fatal(1,"missing bad termination");
  tick();if(ov) $fatal(1,"duplicate abort");
  // A frame begun while down remains discarded if the link returns midframe.
  tv=1;tl=0;tick();run=1;tick();if(mv) $fatal(1,"TX tail leaked after restart");
  tl=1;tick();tv=0;tl=0;tick();tv=1;tl=1;#1;if(!mv) $fatal(1,"next TX frame lost");tick();tv=0;
  // Disable RX at SOP, enable while dropping: only next frame may appear.
  rx_enable=0;rv=1;rl=0;tick();rx_enable=1;tick();if(ov) $fatal(1,"RX tail leaked on enable");
  rl=1;tick();rv=0;tick();if(ov) $fatal(1,"dropped RX frame escaped");
  rv=1;rl=1;tick();if(!ov || !ol) $fatal(1,"next RX frame lost");rv=0;tick();
  // Quiescence finishes a frame admitted before the request.
  tv=1;tl=0;tick();allow_new=0;#1;if(!mv) $fatal(1,"quiesce truncated TX");
  tl=1;tick();tv=0;tick();if(!idle) $fatal(1,"gate failed to drain");
  $display("PASS: stalled RX link loss, bad termination, whole-frame discard, quiescent drain");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
