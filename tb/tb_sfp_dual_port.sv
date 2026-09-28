`timescale 1ns/1ps
module tb_sfp_dual_port;
  reg rst_n=0;
  reg gmii_clk=0,pcs_clk=0;
  always #4 gmii_clk=~gmii_clk;
  initial begin #16 pcs_clk=1;forever #8 pcs_clk=~pcs_clk;end
  wire request_mode,retry;
  reg mode=1,ready=0,seen_retry=0,fail_phy=0,phy_error=0;
  initial begin wait(rst_n);#1000;ready=1;
    forever begin wait(retry!=seen_retry);ready=0;seen_retry=retry;#500;mode=request_mode;#1000;phy_error=fail_phy;ready=!fail_phy;end
  end
  reg clk=0, axis_clk=0, phy_clk=0;
  always #4 clk=~clk;
  always #3.5 axis_clk=~axis_clk;
  always #3.2 phy_clk=~phy_clk;

  wire [63:0] txdata;
  wire [1:0] txhdr;
  reg corrupt_header=0;
  reg corrupt_data=0;
  wire link_up, sync_ok;
  reg [127:0] tx=0;
  reg [15:0] txkeep=0;
  reg txvalid=0,txlast=0;
  wire txready;
  wire [127:0] rx;
  wire [15:0] rxkeep;
  wire rxvalid,rxlast,rxuser;
  reg rxready=0;
  reg [17:0] awaddr=0,araddr=0;
  reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
  reg [31:0] wdata=0;
  reg [3:0] wstrb=0;
  wire awready,wready,bvalid,arready,rvalid;
  wire [31:0] rdata;
  sfp_dual_port #(.RX_HEALTH_WINDOW(127),.AN_BREAK_LINK_CYCLES(8),.AN_LINK_TIMER_CYCLES(8),.AN_IDLE_DETECT_CYCLES(8)) dut (
    .gmii_clk(gmii_clk),.gmii_rst_n(rst_n && ready && !mode),.pcs1g_clk(pcs_clk),.pcs1g_rst_n(rst_n && ready && !mode),
    .gt_mode_10g_i(mode),.gt_ready_i(ready),.gt_error_i(phy_error),.gt_request_10g_o(request_mode),.gt_retry_o(retry),
    .clk(clk),.rst_n(rst_n),.axis_clk(axis_clk),.axis_rst_n(rst_n),
    .gtx_clk(phy_clk),.gtx_rst_n(rst_n && ready && mode),.gth_clk(phy_clk),.gth_rst_n(rst_n && ready && mode),.clk_en(1'b1),
    .stats_request(1'b0),.stats_select(4'b0),
    .txdata_o(txdata),.txcharisk_o(txhdr),.rxdata_i(txdata ^ (corrupt_data ? 64'h1 : 64'h0)),
    .rxcharisk_i(corrupt_header ? 2'b00 : txhdr),.rxdisperr_i(2'b0),.rxnotintable_i(2'b0),
    .sync_ok_o(sync_ok),.an_link_up_o(link_up),
    .s_axis_tdata(tx),.s_axis_tkeep(txkeep),.s_axis_tvalid(txvalid),.s_axis_tlast(txlast),.s_axis_tready(txready),
    .m_axis_tdata(rx),.m_axis_tkeep(rxkeep),.m_axis_tvalid(rxvalid),.m_axis_tlast(rxlast),.m_axis_tuser(rxuser),.m_axis_tready(rxready),
    .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rdata(rdata),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
  task write_enable(input [17:0] address,input [31:0] value=32'h10000000,input [3:0] strobes=4'hf);
    begin
      @(negedge axis_clk);awaddr=address;awvalid=1;
      do @(posedge axis_clk); while(!awready);
      @(negedge axis_clk);awvalid=0;
      repeat(3) @(negedge axis_clk);
      wdata=value;wstrb=strobes;wvalid=1;
      do @(posedge axis_clk); while(!wready);
      @(negedge axis_clk);wvalid=0;
      wait(bvalid);repeat(4) @(negedge axis_clk);
      if(!bvalid) $fatal(1,"write response lost under stall");
      bready=1;@(negedge axis_clk);bready=0;
    end
  endtask
  task read_register(input [17:0] address,input [31:0] expected);
    begin
      @(negedge axis_clk);araddr=address;arvalid=1;
      do @(posedge axis_clk);while(!arready);
      @(negedge axis_clk);arvalid=0;
      wait(rvalid);
      repeat(4) begin
        @(negedge axis_clk);
        if(!rvalid || rdata!==expected) $fatal(1,"read %h got %h expected %h",address,rdata,expected);
      end
      rready=1;@(negedge axis_clk);rready=0;
    end
  endtask
  function [7:0] octet(input integer frame,offset);
    octet=(frame*37+offset*13)^8'ha5;
  endfunction
  integer expected_length=0,expected_frame=0,received=0,received_frames=0;
  reg [145:0] held;
  reg stalled=0;
  integer cycle=0;
  always @(negedge clk) begin cycle=cycle+1;rxready=(cycle%7>2);end
  always @(posedge clk) if(rst_n) begin
    if(stalled && {rxvalid,rxlast,rxkeep,rx}!==held) $fatal(1,"RX changed under backpressure");
    stalled=rxvalid&&!rxready;held={rxvalid,rxlast,rxkeep,rx};
    if(rxvalid&&rxready) begin
      if(rxuser) $fatal(1,"unexpected RX error");
      for(integer b=0;b<16;b=b+1) if(rxkeep[b]) begin
        if(rx[b*8+:8]!==octet(expected_frame,received)) $fatal(1,"payload mismatch frame %0d byte %0d",expected_frame,received);
        received=received+1;
      end
      if(rxlast) begin
        if(received!=expected_length) $fatal(1,"length %0d expected %0d",received,expected_length);
        received=0;received_frames=received_frames+1;
      end
    end
  end
  task packet(input integer n,len,input bit dropped=0);
    integer base,b,prior;
    begin
      expected_frame=n;expected_length=len;prior=received_frames;
      for(base=0;base<len;base=base+16) begin
        @(negedge clk);tx=0;txkeep=0;
        for(b=0;b<16;b=b+1) if(base+b<len) begin tx[8*b+:8]=octet(n,base+b);txkeep[b]=1;end
        txvalid=1;txlast=base+16>=len;
        do @(posedge clk);while(!txready);
      end
      @(negedge clk);txvalid=0;txlast=0;
      if(dropped) begin
        repeat(500) @(posedge phy_clk);
        if(received_frames!=prior) $fatal(1,"corrupt frame escaped RX FIFO");
      end else wait(received_frames==prior+1);
    end
  endtask
  // Icarus may omit the upstream encoder's time-zero always-@* evaluation
  // when its XGMII inputs are initialized constants. Exercise a valid data
  // transition before the first clock; no DUT state or packet is forced.
  initial begin
    force dut.port10.fault_control.txd=64'b0;
    force dut.port10.fault_control.txc=8'b0;
    #1;
    release dut.port10.fault_control.txd;
    release dut.port10.fault_control.txc;
  end
  initial begin
    #200;rst_n=1;
    read_register(18'h4f8,32'h4455414c);read_register(18'h4f0,10000);
    write_enable(18'h404);write_enable(18'h408);
    write_enable(18'h404,0,4'h7);read_register(18'h404,32'h10000000);
    wait(link_up);repeat(30) @(posedge clk);
    packet(0,60);packet(1,64);packet(2,65);packet(3,127);packet(4,1514);
    // Runtime switch in the same elaborated design, with stopped/reset PHY.
    write_enable(18'h4e0,0);wait(!ready);wait(ready);wait(link_up);repeat(80) @(posedge clk);
    read_register(18'h4f0,1000);read_register(18'h4ec,3);
    packet(10,60);packet(11,65);packet(12,1514);
    // Model the PCS reporting an incompatible or faulted peer. Admission
    // must not replace the negotiated 1G duplex flag with a constant.
    force dut.duplex1=0;repeat(20) @(posedge clk);
    if(link_up) $fatal(1,"half-duplex-only 1G peer admitted");
    release dut.duplex1;wait(link_up);
    force dut.fault1=1;repeat(20) @(posedge clk);
    if(link_up) $fatal(1,"faulted 1G peer admitted");
    release dut.fault1;wait(link_up);packet(13,65);
    write_enable(18'h4e0,1);wait(!ready);wait(ready);wait(link_up);repeat(80) @(posedge clk);
    read_register(18'h4f0,10000);packet(20,127);packet(21,1514);
    // Same-mode retry must force a fresh GT reset and reacquire link.
    write_enable(18'h4e0,1);wait(!ready);wait(ready);wait(link_up);repeat(80) @(posedge clk);packet(22,513);
    // Recovery must work even if the GT never becomes ready for a request.
    fail_phy=1;write_enable(18'h4e0,0);wait(phy_error);
    repeat(50) @(posedge clk);if(link_up) $fatal(1,"failed GT advertised link");
    fail_phy=0;write_enable(18'h4e0,0);wait(ready);wait(link_up);repeat(80) @(posedge clk);
    packet(23,1514);
    write_enable(18'h4e0,1);wait(!ready);wait(ready);wait(link_up);
    // Digital reset while the physical GT is already ready and sees no new
    // retry toggle must not wait forever for a ready-low edge.
    if(retry!==0 || mode!==1) $fatal(1,"warm-reset precondition");
    @(negedge clk);rst_n=0;repeat(20) @(posedge clk);@(negedge clk);rst_n=1;
    write_enable(18'h404);write_enable(18'h408);wait(link_up);repeat(80) @(posedge clk);
    packet(24,65);
    $display("PASS: dual MAC/PCS 10G->1G->10G loopback, frame tails, backpressure, split AXI, capability and same-mode retry");$finish;
  end
  initial begin #1000000;$fatal(1,"timeout");end
endmodule
