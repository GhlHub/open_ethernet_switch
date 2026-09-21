`timescale 1ns/1ps
// External-format frame: test both normal and odd-start shortened preambles.
module tb_sfp_rx_preamble;
  logic clk=0, rst_n=0;
  always #4 clk=~clk;
  logic [7:0] data=0;
  logic isk=0;
  wire [7:0] rxd;
  wire dv, er;
  localparam logic [511:0] FRAME = 512'hffffffffffff024b523236010800000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d36ad9ed5;
  byte observed [0:95];
  integer count=0;
  logic error_seen=0;
  gmii_1000base_x_rx dut (
    .clk(clk), .rst_n(rst_n), .rxdata_i(data), .rxcharisk_i(isk),
    .rxdisperr_i(1'b0), .rxnotintable_i(1'b0), .sync_ok_i(1'b1),
    .gmii_rxd_o(rxd), .gmii_rx_dv_o(dv), .gmii_rx_er_o(er)
  );
  always @(posedge clk) if (rst_n) begin
    if (dv) begin
      if (count>=96) $fatal(1,"Unexpected frame length");
      observed[count]=rxd; count=count+1;
      if (er) error_seen=1;
    end
  end
  task automatic sym(input logic [7:0] d, input logic k=0);
    @(negedge clk); data=d; isk=k;
  endtask
  task automatic check_frame(input integer preamble);
    sym(8'hbc,1); sym(8'h50);
    count=0; error_seen=0;
    sym(8'hfb,1);
    repeat (preamble) sym(8'h55);
    sym(8'hd5);
    for (integer i=0;i<64;i=i+1) sym(FRAME[(63-i)*8 +: 8]);
    sym(8'hfd,1); sym(8'hf7,1); sym(8'hbc,1); sym(8'h50);
    if (count!=preamble+65 || error_seen)
      $fatal(1,"Preamble %0d: length=%0d error=%0d",preamble,count,error_seen);
    for (integer i=0;i<preamble;i=i+1)
      if (observed[i]!=8'h55) $fatal(1,"Preamble changed");
    if (observed[preamble]!=8'hd5) $fatal(1,"SFD changed");
    for (integer i=0;i<64;i=i+1)
      if (observed[preamble+1+i]!=FRAME[(63-i)*8 +: 8])
        $fatal(1,"Preamble %0d: lost/changed frame byte %0d",preamble,i);
    $display("PASS: %0d-byte post-/S/ preamble preserves destination, payload and FCS",preamble);
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst_n=1;
    check_frame(6);
    check_frame(5);
    $finish;
  end
  initial begin #10000; $fatal(1,"Timeout"); end
endmodule
