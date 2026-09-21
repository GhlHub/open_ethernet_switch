`timescale 1ns/1ps
// Independent symbol-level checks: /S/ and every idle comma must retain
// the original even position, regardless of GMII start or frame length.
module tb_sfp_tx_alignment;
  logic clk=0, rst_n=0;
  always #4 clk=~clk;
  logic [7:0] data=0;
  logic en=0, er=0;
  wire [7:0] tx;
  wire k;
  integer cycle=0, even_phase=-1, starts=0, terms=0;
  integer payload_index=0, expected_len=0;
  logic in_payload=0;
  gmii_1000base_x_tx dut(.clk(clk),.rst_n(rst_n),.gmii_txd_i(data),
    .gmii_tx_en_i(en),.gmii_tx_er_i(er),.txdata_o(tx),.txcharisk_o(k));
  always @(posedge clk) if (rst_n) begin
    if (k && tx==8'hbc && even_phase<0) even_phase=cycle%2;
    if (k && (tx==8'hbc || tx==8'hfb) && cycle%2!=even_phase)
      $fatal(1,"Comma/start changed even alignment at cycle %0d",cycle);
    if (k && tx==8'hfb) starts++;
    if (!k && tx==8'hd5 && !in_payload) begin
      in_payload=1; payload_index=0;
    end else if (in_payload && !k) begin
      if (tx!==8'(payload_index ^ 8'ha6)) $fatal(1,"Payload changed at %0d",payload_index);
      payload_index++;
    end
    if (k && tx==8'hfd) begin
      if (!in_payload || payload_index!=expected_len) $fatal(1,"Truncated payload");
      in_payload=0; terms++;
    end
    cycle++;
  end
  task automatic frame(input integer phase, input integer length);
    // Drive at falling edges; sample symbol before DUT advances state.
    @(negedge clk);
    while (cycle%2 != phase) @(negedge clk);
    expected_len=length; en=1; data=8'h55;
    repeat(6) begin @(negedge clk); data=8'h55; end
    @(negedge clk); data=8'hd5;
    for(integer i=0;i<length;i++) begin @(negedge clk); data=8'(i ^ 8'ha6); end
    @(negedge clk); en=0;
    repeat(16) @(negedge clk);
  endtask
  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    repeat(8) @(negedge clk);
    frame(0,64); frame(1,64); frame(0,65); frame(1,65);
    if(starts!=4 || terms!=4) $fatal(1,"Missing frames");
    $display("PASS: both GMII start phases and both frame parities preserve framing and payload");
    $finish;
  end
  initial begin #20000; $fatal(1,"Timeout"); end
endmodule
