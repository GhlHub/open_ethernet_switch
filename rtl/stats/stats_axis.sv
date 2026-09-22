// Packet accounting at the CPU virtual port (no FCS/preamble). Malformed
// keep/length and tuser classify the complete frame as bad.
module stats_axis (
  input wire clk, rst_n, valid, ready, last, bad,
  input wire [1:0] keep,
  output wire [3:0][31:0] increment
);
  reg [26:0] length;
  reg error_seen;
  wire fire = valid && ready;
  wire [27:0] total = {1'b0,length} + 28'(keep[0]) + 28'(keep[1]);
  wire error_now = error_seen || bad || keep == 0 || keep == 2'b10 || (!last && keep != 3) || total > 1514 || total < 14;
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
        error_seen <= error_seen || bad || keep != 3 || total > 1514;
      end
    end
  end
endmodule
