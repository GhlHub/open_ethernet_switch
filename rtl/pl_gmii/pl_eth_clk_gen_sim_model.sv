// pl_eth_clk_gen_sim_model.sv
//
// Behavioral stand-in for pl_eth_clk_gen.sv (same port list), for
// Icarus/Verilator simulation -- MMCME4_ADV is a real UltraScale+
// primitive neither tool can simulate (see that file's header; validated
// instead by real synth_design against Vivado, confirmed 0 errors/0
// critical warnings and the exact expected 125.000/300.000/100.000MHz
// outputs via report_clocks). A behavioral clock *multiplier* can't be built
// from ref_clk_25m_i with plain digital logic the way a divider can (you
// can't reconstruct sub-period timing from a slower edge without a real
// PLL) -- gtx_clk_o/idelay_refclk_o here are simply independent free-
// running clocks at the correct nominal rate instead, same
// simplification this project already uses elsewhere for a clock a real
// PLL/MMCM generates (e.g. gth_sfp_sim_model.sv's gth_clk_o).
// ref_clk_25m_i itself is otherwise unused.
//
// locked_o fakes a lock delay (LOCK_DELAY_CYCLES gtx_clk_o cycles after
// rst_n_i releases) purely so a testbench exercising reset sequencing
// around this model sees non-trivial, non-instant lock behavior; not
// calibrated against any real MMCM lock-time spec.
//
// This is the first sim model in this project that free-runs its own
// clocks via `#delay` rather than being driven by an externally-supplied
// clock signal -- needs its own explicit `timescale (every other file
// here either has none, being pure synthesizable RTL with no #delays at
// all, or is a testbench that already declares one); without it, an
// Icarus compilation unit with no explicit timescale doesn't inherit one
// from other files and these delays silently mean something else
// entirely (this actually happened: the very first test run hung on the
// global timeout because of exactly this).

`timescale 1ns/1ps

module pl_eth_clk_gen_sim_model #(
  parameter int LOCK_DELAY_CYCLES = 8
) (
  input  logic ref_clk_25m_i, // unused (see header)
  input  logic rst_n_i,

  output logic gtx_clk_o,
  output logic gtx_rst_n_o,

  output logic idelay_refclk_o,
  output logic idelay_refclk_rst_n_o,

  output logic clk_o,   // 100 MHz -- see pl_eth_clk_gen.sv's header:
  output logic rst_n_o, // intended to be used from the PL0 instance only

  output logic locked_o
);

  wire unused_ref_clk = ref_clk_25m_i;

  logic gtx_clk_q = 1'b0;
  always #4.000 gtx_clk_q = ~gtx_clk_q; // 125 MHz
  assign gtx_clk_o = gtx_clk_q;

  logic idelay_clk_q = 1'b0;
  always #1.667 idelay_clk_q = ~idelay_clk_q; // 300 MHz (approx, see header)
  assign idelay_refclk_o = idelay_clk_q;

  logic clk_q = 1'b0;
  always #5.000 clk_q = ~clk_q; // 100 MHz
  assign clk_o = clk_q;

  logic [$clog2(LOCK_DELAY_CYCLES+1):0] lock_cnt_q;
  logic locked_q;

  always_ff @(posedge gtx_clk_o or negedge rst_n_i) begin
    if (!rst_n_i) begin
      lock_cnt_q <= '0;
      locked_q   <= 1'b0;
    end else if (!locked_q) begin
      if (int'(lock_cnt_q) == LOCK_DELAY_CYCLES) locked_q <= 1'b1;
      else                                 lock_cnt_q <= lock_cnt_q + 1'b1;
    end
  end

  assign locked_o = locked_q;

  logic [1:0] gtx_rst_sync_q;
  always_ff @(posedge gtx_clk_o or negedge locked_q) begin
    if (!locked_q) gtx_rst_sync_q <= 2'b00;
    else           gtx_rst_sync_q <= {gtx_rst_sync_q[0], 1'b1};
  end
  assign gtx_rst_n_o = gtx_rst_sync_q[1];

  logic [1:0] idelay_rst_sync_q;
  always_ff @(posedge idelay_refclk_o or negedge locked_q) begin
    if (!locked_q) idelay_rst_sync_q <= 2'b00;
    else           idelay_rst_sync_q <= {idelay_rst_sync_q[0], 1'b1};
  end
  assign idelay_refclk_rst_n_o = idelay_rst_sync_q[1];

  logic [1:0] clk_rst_sync_q;
  always_ff @(posedge clk_o or negedge locked_q) begin
    if (!locked_q) clk_rst_sync_q <= 2'b00;
    else           clk_rst_sync_q <= {clk_rst_sync_q[0], 1'b1};
  end
  assign rst_n_o = clk_rst_sync_q[1];

endmodule
