// Packet accounting at the CPU virtual port (no FCS/preamble). Malformed
// keep/length and tuser classify the complete frame as bad.
module stats_axis #(parameter integer KEEP_WIDTH=2) (
  input wire clk, rst_n, valid, ready, last, bad,
  input wire [KEEP_WIDTH-1:0] keep,
  output wire [3:0][31:0] increment
);
  reg [26:0] length;
  reg error_seen;
  wire fire = valid && ready;
  reg [27:0] bytes;
  always @* begin
    bytes=0;
    for(integer i=0;i<KEEP_WIDTH;i=i+1) bytes=bytes+28'(keep[i]);
  end
  wire [27:0] total = {1'b0,length}+bytes;
  wire error_now = error_seen || bad || keep == 0 || ((keep & (keep+1'b1)) != 0) || (!last && !(&keep)) || total > 1514 || total < 14;
  assign increment[0] = 32'(fire && last && !error_now);
  assign increment[1] = 32'(fire && last && error_now);
  assign increment[2] = fire && last && !error_now ? 32'(total) : 0;
  assign increment[3] = fire && last && error_now ? 32'(total) : 0;
  always @(posedge clk) begin
    if (!rst_n) begin length <= 0; error_seen <= 0; end
    else if (fire) begin
      if (last) begin length <= 0; error_seen <= 0; end
      else begin
        length <= total[27] ? '1 : total[26:0];
        error_seen <= error_seen || bad || !(&keep) || total > 1514;
      end
    end
  end
endmodule
