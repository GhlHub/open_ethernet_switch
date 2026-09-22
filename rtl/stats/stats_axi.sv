// One outstanding burst per monitored engine/direction (current RTL contract).
// 0 accepted bytes, 1 completed bursts, 2 completed latency sum, 3 max latency,
// 4 address stall cycles, 5 data stall cycles, 6 error responses,
// 7 outstanding cycles. Latency: accepted AW/AR through B/last-R, inclusive.
// Width 30 covers 0.5 s at 100 MHz x 16 bytes; time counters saturate as well.
module stats_axi #(
  parameter integer BYTES = 16,
  parameter bit WRITE = 1
)(
  input wire clk, rst_n,
  input wire address_valid, address_ready, data_valid, data_ready,
  input wire [BYTES-1:0] strobe,
  input wire response_valid, response_ready, response_last,
  input wire [1:0] response,
  input wire request,
  input wire [3:0] select,
  output wire ack,
  output wire [31:0] value
);
  reg active;
  reg [29:0] age;
  wire start = address_valid && address_ready;
  wire finish = response_valid && response_ready && response_last;
  wire [31:0] latency = active ? 32'(age)+1 : 1;
  wire [7:0][31:0] inc;
  integer byte_count;
  always @* begin
    byte_count = 0;
    for (integer i=0;i<BYTES;i=i+1) byte_count = byte_count + int'(strobe[i]);
  end
  assign inc[0] = data_valid && data_ready ? (WRITE ? 32'(byte_count) : 32'(BYTES)) : 0;
  assign inc[1] = 32'(finish);
  assign inc[2] = finish ? latency : 0;
  assign inc[3] = finish ? latency : 0;
  assign inc[4] = 32'(address_valid && !address_ready);
  assign inc[5] = 32'(data_valid && !data_ready);
  assign inc[6] = 32'(response_valid && response_ready && response[1]);
  assign inc[7] = 32'(active || start);
  always @(posedge clk) begin
    if (!rst_n) begin active <= 0; age <= 0; end
    else begin
      if (start) begin active <= 1; age <= 1; end
      else if (active && !(&age)) age <= age + 1'b1;
      if (finish) begin active <= 0; age <= 0; end
    end
  end
  stats_bank #(.WIDTH(30), .MAX_MASK(8'h08)) counters
    (.clk(clk),.rst_n(rst_n),.increment(inc),.request(request),.select(select),.ack(ack),.value(value));
endmodule
