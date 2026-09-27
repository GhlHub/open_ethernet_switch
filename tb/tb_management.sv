`timescale 1ns/1ps
module tb_management #(parameter integer SOURCE_HALF_PERIOD=7, STATS_LIMIT=30);
 reg live_clk=0; always #(SOURCE_HALF_PERIOD) live_clk=~live_clk;
 reg clk=0, source_clk=0, source_run=1, rst_n=0;
 always #5 clk=~clk;
 always #(SOURCE_HALF_PERIOD) if(source_run) source_clk=~source_clk;
 reg [7:0] awaddr=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=1,arvalid=0,rready=0;
 reg [31:0] wdata=0;
 wire awready,wready,bvalid,arready,rvalid;
 wire [31:0] rdata;
 wire [12:0] requests,acks; wire [12:0][31:0] values; wire [12:0][3:0] select,activity;
 reg [1:0][31:0] inc=0;
 switch_management #(.STATS_DDR(1),.STATS_DEBUG(1),.STATS_TIMEOUT(STATS_LIMIT)) csr
 (.clk(clk),.rst_n(rst_n),.s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
  .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
  .s_axi_bvalid(bvalid),.s_axi_bready(bready),.s_axi_bresp(),
  .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
  .s_axi_rdata(rdata),.s_axi_rvalid(rvalid),.s_axi_rready(rready),.s_axi_rresp(),
  .flags_i(4'b0),.idelay_rdy_i(2'b0),.clear_o(),.sfp_status_i(16'b0),.sfp_pcs_status_i(4'b0),
  .sfp_force_disable_o(),.sfp_clr_fault_seen_o(),.sfp_clr_removed_seen_o(),.sfp_clr_lockout_o(),
  .link_up_o(),.link_flush_tog_o(),.link_flush_busy_i(1'b0),.phy_link_i(2'b0),.link_event_set_i(6'b0),.link_irq_o(),
  .gem0_select(select[1:0]),.gem0_activity(activity[1:0]),
  .gem0_req(requests[1:0]),.gem0_acks(acks[1:0]),.gem0_values(values[1:0]),
  .gem1_select(select[3:2]),.gem1_activity(activity[3:2]),
  .gem1_req(requests[3:2]),.gem1_acks(acks[3:2]),.gem1_values(values[3:2]),
  .pl0_select(select[4:4]),.pl0_activity(activity[4:4]),
  .pl0_req(requests[4]),.pl0_acks(acks[4]),.pl0_values(values[4]),
  .pl1_select(select[5:5]),.pl1_activity(activity[5:5]),
  .pl1_req(requests[5]),.pl1_acks(acks[5]),.pl1_values(values[5]),
  .sfp_select(select[6:6]),.sfp_activity(activity[6:6]),
  .sfp_req(requests[6]),.sfp_acks(acks[6]),.sfp_values(values[6]),
  .fabric_select(select[12:7]),.fabric_activity(activity[12:7]),
  .fabric_req(requests[12:7]),.fabric_acks(acks[12:7]),.fabric_values(values[12:7]));
 for(genvar g=0;g<13;g++) begin: banks
  wire [1:0][31:0] scaled;
  wire local_clock = g==1 ? live_clk : source_clk;
  wire local_request = requests[g]; wire [3:0] local_select = select[g];
  wire local_ack; wire [3:0] local_activity; wire [31:0] local_value;
  assign acks[g]=local_ack; assign activity[g]=local_activity; assign values[g]=local_value;
  assign scaled[0]=inc[0]*(g+1);
  assign scaled[1]=inc[1]*(g+1);
  stats_bank #(.N(2),.WIDTH(8)) bank (.clk(local_clock),.rst_n(rst_n),.increment(scaled),
   .request(local_request),.select(local_select),.activity(local_activity),.ack(local_ack),.value(local_value));
 end
 task automatic wr(input [7:0] a,input [31:0] d);
  @(negedge clk);awaddr=a;wdata=d;awvalid=1;wvalid=1;
  @(posedge clk);while(!awready || !wready) @(posedge clk);
  @(negedge clk);awvalid=0;wvalid=0;
  wait(bvalid);@(negedge clk);
 endtask
 task automatic rd(input [7:0] a,input [31:0] expected);
  reg [31:0] held;
  @(negedge clk);araddr=a;arvalid=1;
  @(posedge clk);while(!arready) @(posedge clk);
  @(negedge clk);arvalid=0;
  wait(rvalid);#1;held=rdata;
  if(held !== expected) $fatal(1,"reg %h got %h expected %h",a,held,expected);
  repeat(9) begin @(posedge clk);#1;if(!rvalid || rdata!==held) $fatal(1,"response changed under backpressure"); end
  @(negedge clk);rready=1;@(negedge clk);rready=0;
  repeat(8) @(posedge clk);
  if(source_run) repeat(5) @(posedge source_clk);
 endtask
 initial begin
  repeat(6) @(negedge source_clk);rst_n=1;
  rd('h24,'h53540207);
  @(negedge source_clk);inc[0]=3;inc[1]=2;
  repeat(10) @(negedge source_clk);inc=0;
  rd('h2c,30); rd('h2c,0);
  wr('h28,1);rd('h2c,20);rd('h2c,0);
  // Simultaneous source capture and increment: old interval is zero;
  // the increment is returned once by the next read.
  fork
   rd('h2c,0);
   begin
    wait(banks[0].bank.req_sync==3 && !acks[0]);
    @(negedge source_clk);inc[1]=7;
    @(negedge source_clk);inc[1]=0;
   end
  join
  rd('h2c,7);rd('h2c,0);
  @(negedge source_clk);inc[1]=200;
  repeat(2) @(negedge source_clk);inc=0;
  rd('h2c,32'h800000ff);rd('h2c,0);
  // Timeout must not cancel or retarget a delayed destructive read.
  @(negedge source_clk);inc[1]=19;
  @(negedge source_clk);inc=0;source_run=0;
  rd('h2c,32'hffffffff);
  wr('h28,0);rd('h28,0);
  // A different slot cannot steal the pending destructive read.
  rd('h2c,32'hffffffff);
  if (select[0] != 1) $fatal(1,"pending slot retargeted");
  // Other banks remain serviceable while the source remains stopped.
  wr('h28,'h12);rd('h2c,0);rd('h2c,0);
  repeat(2100) @(posedge clk);
  wr('h28,1);rd('h38,'h111); // pending slot 1, no clock progress

  source_run=1;repeat(10) @(posedge source_clk);
  rd('h2c,19);rd('h2c,0);
  // Stop after destructive capture, before the source can release ACK.
  @(negedge source_clk);inc[1]=9;
  @(negedge source_clk);inc=0;
  fork
    rd('h2c,9);
    begin
      wait(acks[0]); @(negedge source_clk);source_run=0;
    end
  join
  repeat(2100) @(posedge clk);
  rd('h38,'h14); // result consumed but source ACK release is stalled
  wr('h28,0);rd('h2c,32'hffffffff);
  if(select[0]!=1) $fatal(1,"slot changed before ACK release");
  wr('h28,'h12);rd('h2c,0);
  source_run=1;repeat(10) @(posedge source_clk);
  wr('h28,1);rd('h2c,0); // captured nine must not appear twice
  @(negedge source_clk);rst_n=0;
  repeat(6) @(negedge source_clk);rst_n=1;
  @(negedge source_clk);inc[0]=1;inc[1]=2;
  @(negedge source_clk);inc=0;
  for(integer b=0;b<16;b++) begin
   for(integer slot=0;slot<16;slot++) begin
    wr('h28,b*16+slot);
    rd('h2c,(b<13 && slot<2) ? (b+1)*(slot+1) : 0);
    rd('h2c,0);
   end
  end
  $display("PASS: management wrapper all 256 indices, bank isolation, clear, invalid banks, CDC and timeout retry");$finish;
 end
 initial begin #10000000;$fatal(1,"statistics timeout");end
endmodule
