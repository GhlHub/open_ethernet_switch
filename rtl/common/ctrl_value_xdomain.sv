// ctrl_value_xdomain.sv
//
// Generic one-shot value transfer across a clock domain: the source domain
// registers a WIDTH-bit value and flips a toggle bit in the same cycle (so
// the value and the toggle are launched together, not the value first and
// the toggle later). See the CDC limitation below. The destination
// domain's two-flop toggle synchronizer edge-detects the new value and
// pulses valid_o for one cycle while value_o holds the synchronized value.
//
// LIMITATION: equal synchronizer depths do not ensure atomic multi-bit
// sampling or data/event pairing in silicon. Behavioral simulation cannot
// establish metastability safety. A held-data handshake or async FIFO and
// physical CDC review are pending; see docs/cdc-review.md.
// Writes must be spaced by several destination clocks. There is no
// acknowledgement, and closely spaced writes may coalesce or mispair.

module ctrl_value_xdomain #(
  parameter int WIDTH = 8
) (
  input  logic             src_clk,
  input  logic             src_rst_n,
  input  logic [WIDTH-1:0] value_i,
  input  logic             go_i,        // one src_clk pulse: latch value_i

  input  logic             dst_clk,
  input  logic             dst_rst_n,
  output logic [WIDTH-1:0] value_o,
  output logic             valid_o      // one dst_clk pulse when a new value has crossed
);

  logic [WIDTH-1:0] value_q;
  logic             tog_q;

  always_ff @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      value_q <= '0;
      tog_q   <= 1'b0;
    end else if (go_i) begin
      value_q <= value_i;
      tog_q   <= ~tog_q;
    end
  end

  (* ASYNC_REG = "TRUE" *) logic [1:0]       tog_sync;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] value_sync1;
  logic [WIDTH-1:0] value_sync2;
  logic             tog_prev_q;

  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      tog_sync    <= '0;
      value_sync1 <= '0;
      value_sync2 <= '0;
      tog_prev_q  <= 1'b0;
    end else begin
      tog_sync    <= {tog_sync[0], tog_q};
      value_sync1 <= value_q;
      value_sync2 <= value_sync1;
      tog_prev_q  <= tog_sync[1];
    end
  end

  assign value_o = value_sync2;
  assign valid_o = tog_sync[1] ^ tog_prev_q;

endmodule
