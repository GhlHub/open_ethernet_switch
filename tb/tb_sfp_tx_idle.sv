`timescale 1ns/1ps
// Test the GTH word output independently of the GMII packer. Canonical
// 5b/6b and 3b/4b code tables provide a population-count disparity oracle.
module tb_sfp_tx_idle;
  logic clk=0,gclk=0,rst=0;
  always #4 clk=~clk;
  always #8 gclk=~gclk;
  wire [15:0] tx;
  wire [1:0] k;
  logic [15:0] injected_word=0;
  logic [1:0] injected_k=0;
  logic rd=0, prev_comma=0;
  integer i1=0,i2=0;
  sfp_1000base_x_pcs dut(.clk(clk),.rst_n(rst),.gth_clk(gclk),.gth_rst_n(rst),
    .gmii_txd_i(8'b0),.gmii_tx_en_i(1'b0),.gmii_tx_er_i(1'b0),
    .rxdata_i(16'b0),.rxcharisk_i(2'b0),.rxdisperr_i(2'b0),.rxnotintable_i(2'b0),
    .txdata_o(tx),.txcharisk_o(k));
  function automatic logic next_rd(input logic r,input logic [7:0] d,input logic is_k);
    logic [191:0] six;
    logic [31:0] four;
    logic [5:0] s;
    logic [3:0] f;
    begin
      // Entry zero at MSB. Complementing a subcode does not change
      // whether it has nonzero disparity.
      six={6'b011000,6'b100010,6'b010010,6'b110001,6'b001010,6'b101001,6'b011001,6'b000111,
           6'b000110,6'b100101,6'b010101,6'b110100,6'b001101,6'b101100,6'b011100,6'b101000,
           6'b100100,6'b100011,6'b010011,6'b110010,6'b001011,6'b101010,6'b011010,6'b000101,
           6'b001100,6'b100110,6'b010110,6'b001001,6'b001110,6'b010001,6'b100001,6'b010100};
      four={4'b0100,4'b1001,4'b0101,4'b0011,4'b0010,4'b1010,4'b0110,4'b0001};
      s=is_k && d[4:0]==28 ? 6'b110000 : six[(31-d[4:0])*6 +: 6];
      f=four[(7-d[7:5])*4 +: 4];
      next_rd=r ^ ($countones(s)!=3) ^ ($countones(f)!=2);
    end
  endfunction
  task automatic word(input logic [15:0] w,input logic [1:0] kval);
    logic [7:0] b;
    @(negedge gclk); injected_word=w; injected_k=kval;
    @(posedge gclk); #1;
    if(k!==kval) $fatal(1,"K flags changed");
    for(integer j=0;j<2;j++) begin
      b=tx[j*8 +: 8];
      if(prev_comma && !k[j] && w[j*8 +: 8]==8'h50) begin
        if(b!=(rd ? 8'h50 : 8'hc5)) $fatal(1,"Incorrect idle selection RD=%b",rd);
        if(b==8'hc5) i1++; else i2++;
      end else if(b!==w[j*8 +: 8]) $fatal(1,"Non-idle data changed");
      rd=next_rd(rd,b,k[j]);
      if(prev_comma && !k[j] && (b==8'h50 || b==8'hc5) && rd)
        $fatal(1,"Idle did not finish at negative disparity");
      prev_comma=k[j] && b==8'hbc;
    end
  endtask
  initial begin
    force dut.tx_pair_q=injected_word;
    force dut.tx_pair_k_q=injected_k;
    repeat(3) @(negedge gclk);
    rst=1;
    for(integer d=0;d<256;d++) begin
      // Two data bytes, then an idle within one word.
      word({8'hc5,8'(d)},0); word(16'h50bc,1);
      // AN-like comma/config and an idle split across two words.
      word(16'hb5bc,1); word({8'h40,8'(d)},0);
      word(16'hbcc5,2); word(16'hc550,0);
    end
    if(i1==0 || i2==0) $fatal(1,"Missing idle polarity coverage");
    $display("PASS: 256 data values, AN words and both idle alignments; I1=%0d I2=%0d",i1,i2);
    $finish;
  end
  initial begin #100000; $fatal(1,"Timeout"); end
endmodule
