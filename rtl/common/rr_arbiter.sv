// rr_arbiter.sv
//
// Generic one-hot round-robin arbiter. N must be a power of two (true for
// every instantiation in this design: 8 learn ports, 8 lookup ports, and
// (in rtl/buf_mgr) 4 separate instances each padded to 8). Grant is
// combinational on req_i; the priority pointer advances to just past
// whichever requester was granted, so it is served last next time.
//
// The rotate/isolate-lowest-bit arithmetic is inlined directly in the
// always_comb below rather than via local `function automatic` helpers:
// Icarus Verilog 12.0 has a confirmed bug (see rtl/mac_table's
// aging_sweep_fsm.sv for the original writeup, and rtl/buf_mgr's
// queue_mgr.sv/free_list_mgr.sv for where this module hit the same thing)
// where an `automatic` function -- package-scope OR, as it turns out,
// module-local -- called every cycle from more than one instance of the
// module that declares it corrupts simulation, up to and including a
// genuine delta-cycle livelock. This module is instantiated 4 times in
// rtl/buf_mgr (2 in free_list_mgr, 2 in queue_mgr), which is exactly the
// trigger condition, so no automatic function is used here at all now.

module rr_arbiter #(
  parameter int N = 8
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] req_i,
  output logic [N-1:0] grant_o,
  output logic         valid_o
);

  localparam int PW = (N > 1) ? $clog2(N) : 1;

  logic [PW-1:0] ptr_q;
  logic [N-1:0]  req_rot, grant_rot;
  logic [31:0]   rot_sh;

  // rotate right/left by a variable amount in [0, N-1]; shifting an N-bit
  // vector by N (or, via the two halves below, effectively wrapping) drops
  // the shifted-out bits to zero, which is exactly what we want here.
  always_comb begin
    rot_sh    = 32'(ptr_q) + 32'd1;
    req_rot   = (req_i >> rot_sh) | (req_i << (N - rot_sh));           // ror(req_i, rot_sh)
    grant_rot = req_rot & (~req_rot + 1'b1);                            // isolate lowest set bit
    grant_o   = (grant_rot << rot_sh) | (grant_rot >> (N - rot_sh));    // rol(grant_rot, rot_sh)
    valid_o   = |req_i;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptr_q <= '0;
    end else if (valid_o) begin
      for (int i = 0; i < N; i++) begin
        if (grant_o[i]) ptr_q <= i[PW-1:0];
      end
    end
  end

endmodule
