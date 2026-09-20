// port_link_ctrl.sv
//
// Brings the CPU-maintained per-port link state into the switch fabric clock
// domain:
//   * link_up_async_i[p] (level, from the AXI-Lite clock domain) -> two-flop
//     synchronizer -> link_up_o[p]
//   * flush_tog_async_i[p] flips on every "link down" write (even when the port
//     was already down) -> synchronized, edge-detected, then delayed by
//     FLUSH_DELAY cycles -> flush_req_o[p], a one-cycle pulse.
// The delay guarantees link_up_o[p] has already fallen when the flush pulse
// arrives (the two paths' synchronizer latencies can differ by a cycle), so
// nothing can be queued to the port after its flush has run.

module port_link_ctrl #(
  parameter int NUM_PORTS   = 6,
  parameter int FLUSH_DELAY = 4
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [NUM_PORTS-1:0] link_up_async_i,
  input  logic [NUM_PORTS-1:0] flush_tog_async_i,
  output logic [NUM_PORTS-1:0] link_up_o,
  output logic [NUM_PORTS-1:0] flush_req_o
);

  (* ASYNC_REG = "TRUE" *) logic [NUM_PORTS-1:0] up_s1, up_s2;
  (* ASYNC_REG = "TRUE" *) logic [NUM_PORTS-1:0] tog_s1, tog_s2;
  logic [NUM_PORTS-1:0] tog_s3;
  logic [NUM_PORTS-1:0] dly_q [FLUSH_DELAY];

  wire [NUM_PORTS-1:0] tog_edge = tog_s2 ^ tog_s3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      up_s1  <= '0; up_s2  <= '0;
      tog_s1 <= '0; tog_s2 <= '0; tog_s3 <= '0;
      for (int i = 0; i < FLUSH_DELAY; i++) dly_q[i] <= '0;
    end else begin
      up_s1  <= link_up_async_i;
      up_s2  <= up_s1;
      tog_s1 <= flush_tog_async_i;
      tog_s2 <= tog_s1;
      tog_s3 <= tog_s2;
      dly_q[0] <= tog_edge;
      for (int i = 1; i < FLUSH_DELAY; i++) dly_q[i] <= dly_q[i-1];
    end
  end

  assign link_up_o   = up_s2;
  assign flush_req_o = dly_q[FLUSH_DELAY-1];

endmodule
