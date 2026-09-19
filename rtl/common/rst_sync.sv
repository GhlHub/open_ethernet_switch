// rst_sync.sv
//
// Async-assert, synchronous-release reset synchronizer (active-low). The
// async input is typically a raw reset and/or PLL-lock qualifier; the
// output is safe to use as an asynchronous reset in clk's domain.

module rst_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic arst_n_i,
  output logic rst_n_o
);

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n_i) begin
    if (!arst_n_i) sync_q <= '0;
    else           sync_q <= {sync_q[STAGES-2:0], 1'b1};
  end

  assign rst_n_o = sync_q[STAGES-1];

endmodule
