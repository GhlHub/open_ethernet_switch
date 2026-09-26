`timescale 1ns/1ps
module tb_mac_table_dump;
  import mac_table_pkg::*;
  reg clk=0, rst_n=0;
  always #4 clk=~clk;
  reg packet_busy=1;
  wire req,gnt,valid;
  wire [1:0] bank;
  wire [8:0] addr;
  wire [64:0] data;
  reg [7:0] awaddr=0,araddr=0;
  reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
  reg [31:0] wdata=0;
  reg [3:0] wstrb=15;
  wire awready,wready,bvalid,arready,rvalid;
  wire [1:0] bresp,rresp;
  wire [31:0] rdata;
  wire [0:0] dma_awid;
  wire [31:0] dma_awaddr;
  wire [7:0] dma_awlen;
  wire [2:0] dma_awsize;
  wire [1:0] dma_awburst;
  wire dma_awvalid,dma_wvalid,dma_wlast,dma_bready;
  wire [127:0] dma_wdata;
  wire [15:0] dma_wstrb;
  reg dma_awready=0,dma_wready=0,dma_bvalid=0,dma_bid=0;
  reg [1:0] dma_bresp=0;
  reg allow_aw=0,fail_response=0,wrong_id=0;
  integer error_burst=1, learn_preemptions=0, aging_preemptions=0;
  reg age_tick=0;
  reg [7:0] learn_req=0,lookup_req=0;
  reg [7:0][47:0] learn_mac='0,lookup_mac='0;
  wire [7:0] learn_busy,lookup_busy,lookup_valid,lookup_hit;
  wire [7:0][7:0] lookup_mask;
  mac_table_dump dut (
    .clk(clk),.rst_n(rst_n),.packet_busy_i(packet_busy),
    .table_req_o(req),.table_bank_o(bank),.table_addr_o(addr),
    .table_gnt_i(gnt),.table_valid_i(valid),.table_data_i(data),
    .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
    .m_axi_awid(dma_awid),.m_axi_awaddr(dma_awaddr),.m_axi_awlen(dma_awlen),
    .m_axi_awsize(dma_awsize),.m_axi_awburst(dma_awburst),
    .m_axi_awvalid(dma_awvalid),.m_axi_awready(dma_awready),
    .m_axi_wdata(dma_wdata),.m_axi_wstrb(dma_wstrb),.m_axi_wlast(dma_wlast),
    .m_axi_wvalid(dma_wvalid),.m_axi_wready(dma_wready),
    .m_axi_bid(dma_bid),.m_axi_bresp(dma_bresp),.m_axi_bvalid(dma_bvalid),.m_axi_bready(dma_bready)
  );
  mac_addr_table_top tbl (
    .clk(clk),.rst_n(rst_n),.dump_req_i(req),.dump_bank_i(bank),.dump_addr_i(addr),
    .dump_gnt_o(gnt),.dump_valid_o(valid),.dump_data_o(data),
    .age_tick_i(age_tick),.default_age_i(9'd300),.flush_req_i(8'd0),.flush_busy_o(),
    .learn_req_i(learn_req),.learn_mac_i(learn_mac),.learn_busy_o(learn_busy),
    .lookup_req_i(lookup_req),.lookup_mac_i(lookup_mac),.lookup_busy_o(lookup_busy),
    .lookup_result_valid_o(lookup_valid),.lookup_result_hit_o(lookup_hit),
    .lookup_result_port_mask_o(lookup_mask)
  );
  // Distinct values in every row/bank catch lost, repeated or reordered reads.
  function automatic [64:0] entry(input integer index);
    entry={48'h020000000000+48'(index),8'(1<<(index%8)),9'(index%512)};
  endfunction
  for (genvar b=0;b<4;b++) begin: init_banks
    initial begin
      #1;
      for (integer j=0;j<512;j++) tbl.g_banks[b].u_bank.mem[j]=entry(b*512+j);
    end
    always @(posedge clk) if(rst_n && req && bank==b && !gnt) begin
      if(tbl.learn_bus_req)learn_preemptions=learn_preemptions+1;
      if(tbl.g_banks[b].aging_bus_req)aging_preemptions=aging_preemptions+1;
    end
    // Dump must never win over either existing client.
    always @(posedge clk) if (rst_n && tbl.dump_grants[b] &&
        (tbl.learn_bus_req || tbl.g_banks[b].aging_bus_req))
      $fatal(1,"table priority");
  end
  reg [127:0] expected[0:2047];
  integer reads=0,writes=0,bursts=0,beat=0,cycle=0,bdelay=0,run=0,maxrun=0;
  reg pending=0,transaction=0,aw_stalled=0,w_stalled=0;
  reg [31:0] held_aw;
  reg [127:0] held_w;
  reg held_last;
  // Scoreboard records values when RAM responses arrive, allowing aging/learning
  // to modify the live table while the scan is in flight.
  always @(posedge clk) if (rst_n) begin
    if (valid) begin
      expected[reads]={31'd0,(data[8:0]!=0),16'(reads),7'd0,data[8:0],8'd0,data[16:9],data[64:17]};
      reads=reads+1;
    end
    if (req && gnt) begin run=run+1;if(run>maxrun)maxrun=run;end else run=0;
    if (aw_stalled && (!dma_awvalid || dma_awaddr!==held_aw)) $fatal(1,"AW stability");
    if (w_stalled && (!dma_wvalid || dma_wdata!==held_w || dma_wlast!==held_last)) $fatal(1,"W stability");
    aw_stalled=dma_awvalid&&!dma_awready;held_aw=dma_awaddr;
    w_stalled=dma_wvalid&&!dma_wready;held_w=dma_wdata;held_last=dma_wlast;
    if (dma_awvalid && dma_awready) begin
      if(transaction || dma_awaddr!==32'h22000000+bursts*256 ||
          dma_awlen!=15 || dma_awsize!=4 || dma_awburst!=1 || dma_awid!=0 ||
          dma_awaddr[11:0]>3840) $fatal(1,"AXI burst address/shape");
      transaction=1;beat=0;bursts=bursts+1;
    end
    if (dma_wvalid && dma_wready) begin
      if(!transaction || dma_wstrb!==16'hffff || dma_wlast!==(beat==15) ||
          writes>=reads || dma_wdata!==expected[writes])
        $fatal(1,"record %0d mismatch got=%h expected=%h",writes,dma_wdata,expected[writes]);
      writes=writes+1;beat=beat+1;
      if(dma_wlast) begin pending=1;bdelay=7;end
    end
    if(dma_bvalid && dma_bready) begin dma_bvalid<=0;transaction=0;end
  end
  always @(negedge clk) if (rst_n) begin
    cycle=cycle+1;
    dma_awready=allow_aw && cycle%5!=0;
    dma_wready=cycle%7!=0 && cycle%7!=1;
    if(pending) begin
      if(bdelay==0) begin
        dma_bvalid=1;dma_bresp=(fail_response && bursts==error_burst)?2:0;dma_bid=wrong_id;pending=0;
      end else bdelay=bdelay-1;
    end
  end
  task automatic csr_write(input [7:0] a,input [31:0] d,input [3:0] st,input [1:0] response);
    // Deliberately separate AW and W and backpressure the response.
    @(negedge clk);awaddr=a;awvalid=1;
    do @(posedge clk); while(!awready);
    @(negedge clk);awvalid=0;
    repeat(3) @(negedge clk);
    wdata=d;wstrb=st;wvalid=1;
    do @(posedge clk); while(!wready);
    @(negedge clk);wvalid=0;
    wait(bvalid);repeat(3) @(negedge clk);
    if(!bvalid || bresp!==response) $fatal(1,"CSR write %h resp %h",a,bresp);
    bready=1;@(negedge clk);bready=0;
  endtask
  task automatic csr_read(input [7:0] a,output [31:0] d);
    @(negedge clk);araddr=a;arvalid=1;
    do @(posedge clk);while(!arready);
    @(negedge clk);arvalid=0;
    wait(rvalid);d=rdata;
    repeat(3) @(negedge clk);
    if(!rvalid || rdata!==d || rresp!=0) $fatal(1,"CSR read stability");
    rready=1;@(negedge clk);rready=0;
  endtask
  task automatic check_reg(input [7:0] a,input [31:0] expected_value);
    reg [31:0] d;
    csr_read(a,d);if(d!==expected_value)$fatal(1,"CSR %h got %h expected %h",a,d,expected_value);
  endtask
  task automatic clear_scoreboard;
    @(negedge clk);reads=0;writes=0;bursts=0;beat=0;
  endtask
  task automatic complete_dump(input [31:0] status,input [31:0] bytes_done,input [31:0] code);
    wait(dut.done && !dut.busy);
    check_reg(8'h0c,status);check_reg(8'h10,bytes_done);check_reg(8'h14,code);
  endtask
  initial begin : test
    repeat(5) @(negedge clk);rst_n=1;
    check_reg(0,32'h4d445001);
    check_reg(8'h18,2048);check_reg(8'h1c,16);
    // W may precede AW on AXI-Lite.
    @(negedge clk);wdata=32'h22000000;wstrb=15;wvalid=1;
    do @(posedge clk);while(!wready);
    @(negedge clk);wvalid=0;
    repeat(5) @(negedge clk);
    awaddr=4;awvalid=1;
    do @(posedge clk);while(!awready);
    @(negedge clk);awvalid=0;bready=1;
    do @(posedge clk);while(!bvalid);
    if(bresp!=0)$fatal(1,"W-before-AW write");
    @(negedge clk);bready=0;
    check_reg(4,32'h22000000);
    csr_write(8,1,0,0);check_reg(8'h0c,0);
    csr_write(4,32'h22000001,15,0);
    csr_write(8,1,15,2);complete_dump(6,0,2);
    csr_write(4,32'h7fff8100,15,0);
    csr_write(8,1,15,2);complete_dump(6,0,2);
    if(reads || writes || bursts)$fatal(1,"invalid destination caused DMA");
    csr_write(4,32'h22000000,1,2);check_reg(4,32'h7fff8100);
    csr_write(4,32'h22000000,15,0);
    csr_write(8,1,15,0);
    wait(reads==16);
    repeat(30) @(negedge clk);
    if(dma_awvalid || writes || bursts || req)$fatal(1,"HP priority / release table");
    csr_write(8,1,15,2);csr_write(4,32'h23000000,15,2);
    check_reg(4,32'h22000000);
    packet_busy=0;
    wait(dma_awvalid);@(negedge clk);packet_busy=1;
    repeat(20) @(negedge clk);
    if(!dma_awvalid)$fatal(1,"AW withdrawn for later packet request");
    allow_aw=1;
    wait(writes==16);wait(reads==32);
    repeat(30) @(negedge clk);
    if(bursts!=1)$fatal(1,"second burst bypassed packet priority");
    packet_busy=0;
    complete_dump(2,32768,0);
    if(reads!=2048 || writes!=2048 || bursts!=128 || maxrun!=16)
      $fatal(1,"full scan counts/read pipeline %0d %0d %0d %0d",reads,writes,bursts,maxrun);
    // The first scan must preserve exact original data in all four banks.
    for(integer i=0;i<2048;i++) begin
      if(expected[i][47:0]!==48'h020000000000+48'(i) ||
         expected[i][79:64]!==16'(i%512)) $fatal(1,"original table data %0d",i);
    end
    clear_scoreboard();
    // A real learn and age tick during the scan must finish and a port-B
    // lookup must still work. No forced internal grants.
    csr_write(8,1,15,0);
    wait(reads>=34);
    @(negedge clk);age_tick=1;learn_mac[3]=48'h001122334455;learn_req[3]=1;
    @(negedge clk);learn_req=0;
    repeat(12) @(negedge clk);age_tick=0;
    repeat(100) @(negedge clk);
    lookup_mac[0]=48'h001122334455;lookup_req[0]=1;
    @(negedge clk);lookup_req=0;
    wait(lookup_valid[0]);
    if(!lookup_hit[0] || lookup_mask[0]!=8'h08)$fatal(1,"lookup/learn during dump");
    complete_dump(2,32768,0);
    if(learn_preemptions==0 || aging_preemptions==0 ||
       tbl.g_banks[0].u_bank.mem[1][8:0]!==9'd0)
      $fatal(1,"preemption learn=%0d age=%0d, remaining age=%0d",learn_preemptions,aging_preemptions,tbl.g_banks[0].u_bank.mem[1][8:0]);
    clear_scoreboard();fail_response=1;
    csr_write(8,1,15,0);complete_dump(6,0,1);
    if(bursts!=1 || writes!=16)$fatal(1,"continued after BRESP error");
    clear_scoreboard();error_burst=2;
    csr_write(8,1,15,0);complete_dump(6,256,1);
    if(bursts!=2 || writes!=32)$fatal(1,"partial completion accounting");
    clear_scoreboard();fail_response=0;wrong_id=1;
    csr_write(8,1,15,0);complete_dump(6,0,1);
    clear_scoreboard();wrong_id=0;
    csr_write(8,1,15,0);complete_dump(2,32768,0);
    $display("PASS: MAC dump full scans, live learn/age/lookup, burst priority, backpressure, CSR and AXI errors");
    $finish;
  end
  initial begin #2000000;$fatal(1,"timeout");end
endmodule
