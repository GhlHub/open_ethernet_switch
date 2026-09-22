// GEM FIFO observation, in the corresponding RX/TX clock domain. Byte counts
// exclude FCS, preamble and IFG. TX failures count bytes supplied to the GEM,
// not an estimate of how many reached the wire. Full-duplex operation only.
module stats_gem_rx (
  input wire clk, rst_n, wr, sop, eop, error, flush, overflow,
  output wire [3:0][31:0] increment
);
  reg [26:0] length;
  reg active, bad;
  wire [27:0] total = (wr && sop) ? 28'd1 : {1'b0,length} + 28'(wr);
  wire done = (wr && eop) || (flush && active);
  wire failed = error || overflow || bad || flush;
  assign increment[0] = 32'(done && !failed);
  assign increment[1] = 32'(done && failed);
  assign increment[2] = done && !failed ? 32'(total) : 0;
  assign increment[3] = done && failed ? 32'(total) : 0;
  always @(posedge clk) begin
    if (!rst_n) begin length <= 0; active <= 0; bad <= 0; end
    else if (done) begin length <= 0; active <= 0; bad <= 0; end
    else begin
      if (wr) begin length <= total[27] ? '1 : total[26:0]; active <= 1; end
      if (wr && sop) bad <= error || overflow;
      else if (active) bad <= bad || error || overflow;
    end
  end
endmodule
module stats_gem_tx (
  input wire clk, rst_n, valid, sop, error, underflow, complete_toggle,
  input wire [3:0] status,
  output wire [3:0][31:0] increment
);
  reg [26:0] length;
  reg bad, complete_q;
  wire done = complete_toggle != complete_q;
  wire failed = bad || error || underflow || |status;
  assign increment[0] = 32'(done && !failed);
  assign increment[1] = 32'(done && failed);
  assign increment[2] = done && !failed ? (length < 60 ? 32'd60 : 32'(length)) : 0;
  assign increment[3] = done && failed ? 32'(length) : 0;
  always @(posedge clk) begin
    if (!rst_n) begin length <= 0; bad <= 0; complete_q <= 0; end
    else begin
      complete_q <= complete_toggle;
      if (done) begin length <= 0; bad <= 0; end
      if (valid) begin
        if (sop) begin length <= 1; bad <= error || underflow; end
        else if (!(&length)) length <= length + 1'b1;
      end
      if (!(valid && sop) && (error || underflow)) bad <= 1;
    end
  end
endmodule
