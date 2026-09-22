`timescale 1ns/1ps
module tb_ingress_dma_pipeline;
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [NUM_PHYS_PORTS-1:0] frame_ready_i='0, frame_gnt_o, frame_rd_en_o, frame_dma_done_o;
  logic [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0] frame_bufid_i='0;
  logic [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0] frame_length_i='0;
  logic [NUM_PHYS_PORTS-1:0][AXI_DATA_W-1:0] frame_rd_data_i='0;
  logic [BEAT_IDX_W-1:0] frame_rd_addr_o;
  logic [AXI_ID_W-1:0] m_axi_awid, m_axi_bid=0;
  logic [AXI_ADDR_W-1:0] m_axi_awaddr;
  logic [7:0] m_axi_awlen;
  logic [2:0] m_axi_awsize;
  logic [1:0] m_axi_awburst, m_axi_bresp=0;
  logic m_axi_awvalid, m_axi_awready=0;
  logic [AXI_DATA_W-1:0] m_axi_wdata;
  logic [AXI_STRB_W-1:0] m_axi_wstrb;
  logic m_axi_wlast,m_axi_wvalid,m_axi_wready=0,m_axi_bvalid=0,m_axi_bready;
  ingress_dma_wr dut(.*);
  integer cycle=0, port, length, beats, reads, writes, grants, aw_cycle, first_cycle;
  // Keep cross-process completion state visible to older Verilator coroutine
  // optimizers; these variables are written by the monitor and read by tasks.
  integer last_cycle /* verilator public_flat_rw */;
  integer previous_write, tests=0, seed=32'h1234567, dummy;
  bit active=0, seen_aw=0, responded=0, stalled=0, aw_stalled=0;
  bit finished /* verilator public_flat_rw */ = 0;
  bit baseline=0, consecutive=0;
  logic [AXI_DATA_W+AXI_STRB_W:0] held_word;
  logic [AXI_ADDR_W+7:0] held_address;

  function automatic [127:0] payload(input integer p,input integer beat);
    return {32'h10203040 ^ (p<<16) ^ beat,32'habcdef00 ^ beat,
            32'h91827364 ^ (beat<<8) ^ p,32'h55aa00ff ^ beat ^ (p<<24)};
  endfunction

  // Same one-cycle registered read behavior as ingress_port_wr's frame RAM.
  for (genvar p=0;p<NUM_PHYS_PORTS;p++) begin : ram
    always @(posedge clk) if (rst_n && frame_rd_en_o[p])
      frame_rd_data_i[p] <= payload(p,int'(frame_rd_addr_o));
  end

  always @(posedge clk) begin
    cycle=cycle+1;
    if (rst_n && active) begin
      if (stalled && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast} !== held_word))
        $fatal(1,"AXI write changed under backpressure");
      stalled=m_axi_wvalid && !m_axi_wready;
      held_word={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
      if (aw_stalled && (!m_axi_awvalid || {m_axi_awaddr,m_axi_awlen} !== held_address))
        $fatal(1,"AXI address changed under backpressure");
      aw_stalled=m_axi_awvalid && !m_axi_awready;
      held_address={m_axi_awaddr,m_axi_awlen};
      if (|frame_gnt_o) begin
        if (frame_gnt_o !== (NUM_PHYS_PORTS'(1)<<port) || grants!=0) $fatal(1,"wrong/repeated grant");
        grants=grants+1;
      end
      if (|frame_rd_en_o) begin
        if (frame_rd_en_o !== (NUM_PHYS_PORTS'(1)<<port) || int'(frame_rd_addr_o)!=reads || reads>=beats)
          $fatal(1,"wrong/repeated/out-of-range RAM read length=%0d reads=%0d",length,reads);
        reads=reads+1;
      end
      if (m_axi_awvalid && m_axi_awready) begin
        if (seen_aw || m_axi_awaddr !== DDR_BASE_ADDR+32'(port+7)*BUFFER_BYTES ||
            int'(m_axi_awlen)!=beats-1 || m_axi_awsize!=4 || m_axi_awburst!=1 || m_axi_awid!=0)
          $fatal(1,"bad address transaction");
        seen_aw=1; aw_cycle=cycle;
      end
      if (m_axi_wvalid && m_axi_wready) begin
        if (!seen_aw || writes>=beats || m_axi_wdata !== payload(port,writes))
          $fatal(1,"bad/duplicate write: length=%0d beat=%0d data=%h expected=%h",length,writes,m_axi_wdata,payload(port,writes));
        if (m_axi_wlast !== (writes==beats-1)) $fatal(1,"bad WLAST");
        if (m_axi_wstrb !== ((writes==beats-1 && (length%16!=0))?16'((1<<(length%16))-1):16'hffff))
          $fatal(1,"bad WSTRB for length %0d",length);
        if (consecutive && writes>0 && cycle!=previous_write+(baseline?2:1))
          $fatal(1,"throughput bubble length=%0d beat=%0d cycle gap=%0d",length,writes,cycle-previous_write);
        if (writes==0) first_cycle=cycle;
        previous_write=cycle;writes=writes+1;
        if (writes==beats) last_cycle=cycle;
      end
      if (m_axi_bvalid && m_axi_bready) begin
        if (writes!=beats || responded) $fatal(1,"bad response ordering");
        responded=1;
      end
      if (|frame_dma_done_o) begin
        if (frame_dma_done_o !== (NUM_PHYS_PORTS'(1)<<port) || !responded || reads!=beats || grants!=1)
          $fatal(1,"early/incorrect completion");
        finished=1;
      end
    end
  end

  task automatic reset_engine;
    @(negedge clk);active=0;rst_n=0;frame_ready_i=0;
    m_axi_awready=0;m_axi_wready=0;m_axi_bvalid=0;
    repeat(3) @(negedge clk);
    if (m_axi_wvalid || m_axi_awvalid || (|frame_dma_done_o) || (|frame_rd_en_o)) $fatal(1,"reset did not quiesce engine");
    rst_n=1;
    repeat(2) @(negedge clk);
  endtask

  task automatic start_frame(input integer p,input integer n,input bit fast);
    @(negedge clk);
    port=p;length=n;beats=(n+15)/16;reads=0;writes=0;grants=0;
    seen_aw=0;responded=0;finished=0;stalled=0;aw_stalled=0;
    last_cycle=0;previous_write=0;consecutive=fast;
    frame_length_i='0;frame_bufid_i='0;
    // Whole packed-vector assignments avoid variable-index Icarus hazards.
    frame_length_i=(NUM_PHYS_PORTS*LENGTH_W)'(n) << (p*LENGTH_W);
    frame_bufid_i=(NUM_PHYS_PORTS*BUF_ID_W)'(32'(p+7)) << (p*BUF_ID_W);
    frame_ready_i=NUM_PHYS_PORTS'(1)<<p;active=1;
  endtask

  task automatic run_frame(input integer p,input integer n,input integer mode);
    integer ticks, stall_left, b_delay;
    start_frame(p,n,mode==0);
    ticks=0;stall_left=20;b_delay=17;
    while (!finished) begin
      ticks=ticks+1;
      if (ticks>10000) $fatal(1,"transaction timeout length=%0d grants=%0d reads=%0d writes=%0d aw=%0b b=%0b state=%0d ready=%b",n,grants,reads,writes,seen_aw,responded,dut.state_q,frame_ready_i);
      m_axi_awready=(mode!=4 || ticks>32) && (mode!=1 || ($urandom%4!=0));
      case(mode)
        1: m_axi_wready=($urandom%3!=0);
        2: begin
          m_axi_wready=1;
          if (m_axi_wvalid && m_axi_wlast && stall_left>0) begin
            m_axi_wready=0;stall_left=stall_left-1;
          end
        end
        3: m_axi_wready=(ticks>40);
        default: m_axi_wready=1;
      endcase
      m_axi_bvalid=(last_cycle!=0 && cycle-last_cycle>=b_delay && !responded);
      @(negedge clk);
      if (grants!=0) frame_ready_i=0;
      if (mode==3 && ticks==35 && !baseline && reads!=2) $fatal(1,"read-ahead did not stop at two reserved words");
    end
    if (mode==0 && n==1500)
      $display("PERF baseline=%0d length=1500 beats=%0d AW-to-last=%0d cycles data-span=%0d cycles",baseline,beats,last_cycle-aw_cycle,last_cycle-first_cycle+1);
    active=0;frame_ready_i=0;m_axi_bvalid=0;m_axi_wready=0;m_axi_awready=0;
    tests=tests+1;
    repeat(2) @(negedge clk);
  endtask

  initial begin
    baseline=$test$plusargs("baseline");
    if ($value$plusargs("seed=%d",seed)) begin end
    dummy=$urandom(seed);
    reset_engine();
    run_frame(0,1500,0);
    // Exhaustive length/partial strobe coverage, spread across all ports.
    for (integer n=1;n<=BUFFER_BYTES;n++) run_frame(n%NUM_PHYS_PORTS,n,0);
    for (integer k=0;k<300;k++) run_frame(k%NUM_PHYS_PORTS,1+($urandom%BUFFER_BYTES),1);
    for (integer p=0;p<NUM_PHYS_PORTS;p++) begin
      run_frame(p,1,2);run_frame(p,1514,2);run_frame(p,2048,3);run_frame(p,64,4);
    end
    // Reset while address is stalled, while RAM reads are buffered, and
    // while the write response is pending; follow each with a fresh frame.
    for (integer stage=0;stage<3;stage++) begin
      start_frame(stage,1500,0);
      m_axi_awready=(stage!=0);m_axi_wready=(stage==2);m_axi_bvalid=0;
      if (stage==0) wait(m_axi_awvalid);
      if (stage==1) begin wait(m_axi_wvalid);repeat(5) @(negedge clk);end
      if (stage==2) wait(m_axi_bready);
      reset_engine();run_frame(stage,47,0);
    end
    $display("PASS: %0d DMA cases; all lengths, backpressure stability, delayed AW/B, reset and throughput",tests);
    $finish;
  end
  initial begin #100000000; $fatal(1,"watchdog");end
endmodule
