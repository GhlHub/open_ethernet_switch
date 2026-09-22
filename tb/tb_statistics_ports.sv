`timescale 1ns/1ps
module tb_statistics_ports;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg wr=0,sop=0,eop=0,error=0,flush=0,overflow=0;
 wire [3:0][31:0] rx_inc;
 reg valid=0,txsop=0,txerror=0,underflow=0,toggle=0;reg [3:0] status=0;
 wire [3:0][31:0] tx_inc;
 reg av=0,ready=0,last=0,bad=0;reg [1:0] keep=0;
 wire [3:0][31:0] axis_inc;
 reg [63:0] rx_total[4],tx_total[4],axis_total[4];
 stats_gem_rx rx(.clk(clk),.rst_n(rst_n),.wr(wr),.sop(sop),.eop(eop),.error(error),.flush(flush),.overflow(overflow),.increment(rx_inc));
 stats_gem_tx tx(.clk(clk),.rst_n(rst_n),.valid(valid),.sop(txsop),.error(txerror),.underflow(underflow),.complete_toggle(toggle),.status(status),.increment(tx_inc));
 stats_axis axis(.clk(clk),.rst_n(rst_n),.valid(av),.ready(ready),.last(last),.bad(bad),.keep(keep),.increment(axis_inc));
 always @(posedge clk) for(integer i=0;i<4;i++) begin
  if(!rst_n) begin rx_total[i]<=0;tx_total[i]<=0;axis_total[i]<=0;end
  else begin rx_total[i]<=rx_total[i]+rx_inc[i];tx_total[i]<=tx_total[i]+tx_inc[i];axis_total[i]<=axis_total[i]+axis_inc[i];end
 end
 task automatic rx_frame(input integer length,input bit failed,abort_frame);
  for(integer i=0;i<length;i++) begin
   @(negedge clk);wr=1;sop=i==0;eop=i==length-1 && !abort_frame;error=eop && failed;
  end
  @(negedge clk);wr=0;sop=abort_frame;eop=0;error=0;flush=abort_frame;
  @(negedge clk);flush=0;sop=0;
 endtask
 task automatic tx_frame(input integer length,input bit failed);
  for(integer i=0;i<length;i++) begin @(negedge clk);valid=1;txsop=i==0;end
  @(negedge clk);valid=0;txsop=0;
  repeat(5) @(negedge clk);status=failed?8:0;toggle=~toggle;
  repeat(5) @(negedge clk);status=0;
 endtask
 initial begin
  repeat(4) @(negedge clk);rst_n=1;
  rx_frame(60,0,0);rx_frame(63,1,0);rx_frame(17,0,1);
  tx_frame(40,0);tx_frame(29,1);
  // Seven 2-byte transfers, with three stalled cycles in the middle.
  av=1;ready=1;keep=3;
  repeat(3) @(negedge clk);ready=0;
  repeat(3) @(negedge clk);ready=1;
  repeat(3) @(negedge clk);last=1;
  @(negedge clk);last=0;
  // malformed one-byte frame
  keep=1;last=1;
  @(negedge clk);av=0;last=0;
  repeat(3) @(negedge clk);
  if(rx_total[0]!=1 || rx_total[1]!=2 || rx_total[2]!=60 || rx_total[3]!=80) $fatal(1,"RX error/flush accounting");
  if(tx_total[0]!=1 || tx_total[1]!=1 || tx_total[2]!=60 || tx_total[3]!=29) $fatal(1,"TX completion/status/padding accounting");
  if(axis_total[0]!=1 || axis_total[1]!=1 || axis_total[2]!=14 || axis_total[3]!=1) $fatal(1,"AXIS accounting %0d %0d %0d %0d",axis_total[0],axis_total[1],axis_total[2],axis_total[3]);
  $display("PASS: GEM RX errors/flush, TX completion/error/padding, CPU AXIS backpressure/length");$finish;
 end
 initial begin #100000;$fatal(1,"port statistics timeout");end
endmodule
