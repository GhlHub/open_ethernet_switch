`timescale 1ns/1ps
module tb_sfp_dual_reconfigure;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,request=1,retry=0,lock=1,txdone=1,rxdone=1;
 wire mode,ready,error,reset,en,we;wire [9:0] addr;wire [15:0] di;
 reg [15:0] dout=0;reg rdy=0;
 reg [15:0] mem[0:1023],original[0:1023];reg no_reply=0,bad_readback=0;
 integer writes=0,reset_age=0;
 always @(posedge clk) begin
  // Wizard completion flags can retain their previous high state until its
  // sequential TX-then-RX reset sequence begins after reset-all deasserts.
  if(reset) begin reset_age<=0;txdone<=1;rxdone<=1;end
  else begin
   reset_age<=reset_age+1;
   txdone<=reset_age<4 || reset_age>=8;
   rxdone<=reset_age<10 || reset_age>=15;
  end
  if(ready && reset_age<16) $fatal(1,"stale reset-done released the port early");
 end
 sfp_dual_reconfigure #(.DRP_TIMEOUT(16),.LOCK_TIMEOUT(100),.RESET_CYCLES(8)) dut(
 .clk(clk),.rst_n(rst_n),.request_10g(request),.retry_toggle(retry),.power_good(1'b1),.pll_locked(lock),.tx_done(txdone),.rx_done(rxdone),
 .mode_10g(mode),.ready(ready),.error(error),.gt_reset(reset),.drp_addr(addr),.drp_di(di),.drp_en(en),.drp_we(we),.drp_do(dout),.drp_rdy(rdy));
 reg [5:0] idx=0;wire [9:0] ra;wire [15:0] mask,value;wire last;
 sfp_dual_drp_rom rom(idx,mode,ra,mask,value,last);
 always @(posedge clk) begin
  rdy<=0;
  if(en && !no_reply) begin
   rdy<=1;
   if(we) begin mem[addr]<=di;writes<=writes+1;end
   dout<=mem[addr] ^ (bad_readback && !we && dut.state==6?16'hffff:16'h0);
  end
  if(ready && (reset || error)) $fatal(1,"unsafe ready");
  if(en && !reset) $fatal(1,"DRP outside reset");
 end
 task verify;
  begin
   for(integer i=0;i<37;i=i+1) begin
    idx=i;#1;
    if((mem[ra]&mask)!==value) $fatal(1,"wrong DRP value %h",ra);
    if((mem[ra]&~mask)!==(original[ra]&~mask)) $fatal(1,"reserved bits changed %h",ra);
   end
  end
 endtask
 task change(input bit m);
  begin @(negedge clk);request=m;retry=!retry;wait(!ready);wait(ready);verify();end
 endtask
 initial begin
  for(integer i=0;i<1024;i=i+1) begin mem[i]=16'h5aa5 ^ i;original[i]=mem[i];end
  #100;rst_n=1;wait(ready);verify();
  change(0);change(1);change(0);
  @(negedge clk);no_reply=1;retry=!retry;
  wait(error);#1;if(ready || !reset) $fatal(1,"DRP timeout did not fail closed");
  @(negedge clk);no_reply=0;change(1);
  @(negedge clk);bad_readback=1;retry=!retry;wait(error);#1;
  if(ready || !reset) $fatal(1,"readback mismatch did not fail closed");
  @(negedge clk);bad_readback=0;change(0);
  @(negedge clk);lock=0;retry=!retry;wait(error);#1;
  if(ready || !reset) $fatal(1,"PLL timeout did not fail closed");
  @(negedge clk);lock=1;change(1);
  $display("PASS: reversible DRP, preserved reserved bits, same-mode retry, DRP/readback/PLL failures and recovery (%0d writes)",writes);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
