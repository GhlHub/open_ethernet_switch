`timescale 1ns/1ps
module tb_statistics_axi;
 reg clk=0,rst_n=0; always #5 clk=~clk;
 reg av=0,ar=0,dv=0,dr=0,rv=0,rr=0,rl=1;
 reg [15:0] strobe=0; reg [1:0] response=0;
 reg request=0;reg [3:0] select=0;wire ack;wire [31:0] value;
 stats_axi dut(.clk(clk),.rst_n(rst_n),.address_valid(av),.address_ready(ar),
 .data_valid(dv),.data_ready(dr),.strobe(strobe),.response_valid(rv),.response_ready(rr),
 .response_last(rl),.response(response),.request(request),.select(select),.ack(ack),.value(value));
 task automatic get(input integer index,expected);
  @(negedge clk);select=index;request=1;wait(ack);#1;
  if(value!==expected) $fatal(1,"AXI stat %0d got %0d expected %0d",index,value,expected);
  @(negedge clk);request=0;wait(!ack);@(negedge clk);
 endtask
 initial begin
  repeat(3) @(negedge clk);rst_n=1;
  av=1;repeat(2) @(negedge clk); // 2 address stalls
  ar=1;@(negedge clk);av=0;ar=0; // accept address, age1
  dv=1;strobe=16'hffff;@(negedge clk); // one data stall, age2
  dr=1;@(negedge clk);strobe=16'h0007; // 16 bytes, age3
  @(negedge clk);dv=0;dr=0; // 3 bytes, age4
  rv=1;rr=1;response=2;@(negedge clk);rv=0;rr=0; // completion latency5
  get(0,19);get(1,1);get(2,5);get(3,5);get(4,2);get(5,1);get(6,1);get(7,5);
  for(integer i=0;i<8;i=i+1) get(i,0);
  // Reading a latency counter while a burst is active must not reset its age.
  av=1;ar=1;@(negedge clk);av=0;ar=0;
  get(2,0);
  begin
    integer expected;
    expected=dut.age+1;
    rv=1;rr=1;response=0;@(negedge clk);rv=0;rr=0;
    get(2,expected);get(3,expected);
  end
  $display("PASS: AXI bytes/strobes, latency/max, stalls, errors, in-flight interval crossing");$finish;
 end
 initial begin #100000;$fatal(1,"AXI statistics timeout");end
endmodule
