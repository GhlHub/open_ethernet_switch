// Saturating read/clear counters in their event clock domain. Bundled-data
// four-phase mailbox: caller holds select and request until ack; data remains
// stable until the next request. A simultaneous increment belongs to the NEXT
// interval. Bit 31 reports saturation; payload is zero-extended to 31 bits.
module stats_bank #(
  parameter integer N = 8,
  parameter integer WIDTH = 27,
  parameter [N-1:0] MAX_MASK = 0
)(
  input wire clk, rst_n,
  input wire [N-1:0][31:0] increment,
  input wire request,
  input wire [3:0] select,
  output reg ack,
  output reg [31:0] value
);
  (* ASYNC_REG = "TRUE" *) reg [1:0] req_sync;
  reg [WIDTH-1:0] count [N];
  reg [N-1:0] overflow;
  wire capture = req_sync[1] && !ack;
  for (genvar g=0; g<N; g=g+1) begin : counters
    wire [32:0] sum = {1'b0,32'(count[g])} + {1'b0,increment[g]};
    always @(posedge clk) begin
      if (!rst_n) begin count[g] <= 0; overflow[g] <= 0; end
      else if (capture && select == g) begin
        count[g] <= (increment[g] > {WIDTH{1'b1}}) ? {WIDTH{1'b1}} : WIDTH'(increment[g]);
        overflow[g] <= increment[g] > {WIDTH{1'b1}};
      end else if (MAX_MASK[g]) begin
        if (increment[g] > {WIDTH{1'b1}}) begin count[g] <= '1; overflow[g] <= 1; end
        else if (increment[g] > count[g]) count[g] <= WIDTH'(increment[g]);
      end else if (sum > {WIDTH{1'b1}}) begin count[g] <= '1; overflow[g] <= 1; end
      else count[g] <= sum[WIDTH-1:0];
    end
  end
  always @(posedge clk) begin
    if (!rst_n) begin req_sync <= 0; ack <= 0; value <= 0; end
    else begin
      req_sync <= {req_sync[0],request};
      if (!req_sync[1]) ack <= 0;
      if (capture) begin
        ack <= 1;
        if (select < N) value <= {overflow[select],31'(count[select])};
        else value <= 0;
      end
    end
  end
endmodule
