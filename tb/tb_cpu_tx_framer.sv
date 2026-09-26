`timescale 1ns/1ps
module tb_cpu_tx_framer;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0;
  reg [15:0] s_data=0;
  reg [1:0] s_keep=0;
  reg s_valid=0,s_last=0,m_ready=0,frame_done=0;
  wire s_ready,m_valid,m_last,directed;
  wire [15:0] m_data;
  wire [1:0] m_keep;
  wire [5:0] dest_mask;
  cpu_tx_framer dut(.*);
  integer frames=0,beat=0,delay_left=0;
  bit checking=1;
  reg old_directed;
  reg [5:0] old_mask;
  always @(negedge clk) begin
    m_ready = $urandom_range(0,3)!=0;
    frame_done=0;
    if (!rst_n) delay_left=0;
    else if (delay_left>0) begin
      delay_left=delay_left-1;
      if (delay_left==0) frame_done=1;
    end
  end
  always @(posedge clk) if (rst_n && checking) begin
    if (delay_left>0 || frame_done) begin
      if(s_ready || m_valid) $fatal(1,"next header accepted before prior enqueue");
      if(directed!==old_directed || dest_mask!==old_mask) $fatal(1,"metadata changed before enqueue");
    end
    if(m_valid && m_ready) begin
      if(frames>=20) $fatal(1,"unexpected payload from malformed header");
      if(m_data !== 16'(frames*256+beat)) $fatal(1,"header leaked or payload changed: frame %0d beat %0d data %h",frames,beat,m_data);
      if(directed !== 1'(frames%2) || dest_mask !== (frames%2 ? 6'(1<<(frames%5)):6'b0)) $fatal(1,"wrong per-frame metadata");
      if(m_last !== (beat==frames%9)) $fatal(1,"TLAST mismatch");
      if(m_keep !== ((beat==frames%9 && frames%3==0)?2'b01:2'b11)) $fatal(1,"TKEEP mismatch");
      if(m_last) begin
        old_directed=directed;old_mask=dest_mask;
        delay_left=17+frames%7;frames=frames+1;beat=0;
      end else beat=beat+1;
    end
  end
  task automatic put(input [15:0] data,input [1:0] keep,input bit last);
    @(negedge clk);s_data=data;s_keep=keep;s_last=last;s_valid=1;
    do @(posedge clk); while(!s_ready);
    @(negedge clk);s_valid=0;
  endtask
  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    // Invalid magic, reserved bits, mask without directed, partial header,
    // CPU-source bit, and header-only transfer must not produce any payload.
    put(16'h0055,3,0);put(16'h1234,3,1);
    put(16'hA580,3,0);put(16'h1234,3,1);
    put(16'hA501,3,0);put(16'h1234,3,1);
    put(16'hA500,1,0);put(16'h1234,3,1);
    put(16'hA560,3,0);put(16'h1234,3,1);
    put(16'hA544,3,1);
    for(integer f=0;f<20;f=f+1) begin
      put(16'hA500 | (f%2 ? (16'h40 | (1<<(f%5))) : 0),3,0);
      for(integer b=0;b<=f%9;b=b+1)
        put(16'(f*256+b),(b==f%9 && f%3==0)?1:3,b==f%9);
    end
    wait(frames==20);wait(frame_done);repeat(3) @(negedge clk);
    checking=0;
    // Reset cancels partial metadata/payload; upstream must reset too.
    put(16'hA541,3,0);
    @(negedge clk);rst_n=0;
    repeat(3) @(negedge clk);rst_n=1; #1;
    if(directed || dest_mask) $fatal(1,"reset retained metadata");
    put(16'hA548,3,0);put(16'hbeef,3,1);
    @(negedge clk);rst_n=0;
    repeat(3) @(negedge clk);rst_n=1; #1;
    if(directed || dest_mask || !s_ready) $fatal(1,"reset failed during enqueue wait");
    $display("ALL TESTS PASSED: CPU metadata, stripping, malformed headers, backpressure, enqueue delay and reset");$finish;
  end
  initial begin #200000; $fatal(1,"timeout"); end
endmodule
