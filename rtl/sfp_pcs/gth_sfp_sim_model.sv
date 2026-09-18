// gth_sfp_sim_model.sv
//
// Behavioral stand-in for gth_sfp_wrapper.sv, same port list, for
// Icarus/Verilator simulation (real GTHE4_CHANNEL is a UNISIM primitive
// neither tool can simulate -- see gth_sfp_wrapper.sv's header; that
// file was instead validated by actually elaborating it against
// Vivado's own xsim + UNISIM GTHE4_CHANNEL behavioral model). No serial
// encoding is modeled: txp_o/txn_o/rxp_i/rxn_i are unused placeholders
// (differential pins can't be meaningfully driven/observed by a plain
// testbench anyway), and gtrefclk_p_i/gtrefclk_n_i are only used as this
// model's own clock source (gtrefclk_n_i is ignored, matching how a real
// IBUFDS_GTE4 behavioral model treats its own I/IB pair in simulation --
// the same simplification tb_sfp_1000base_x_pcs.sv/tb_sfp_port_top.sv
// already make for gtx_clk/gth_clk generation).
//
// txdata_i/txcharisk_i are looped straight back to rxdata_o/rxcharisk_o
// with a few registered cycles of latency (loopback_delay_cycles_i,
// default 3 -- arbitrary but nonzero, so a testbench relying on this
// model can't accidentally depend on same-cycle combinational timing
// that a real serial link could never provide), rxdisperr_o/
// rxnotintable_o tied low except when force_rx_error_i injects a fixed
// pattern on both lanes (for sync-loss/error-handling tests, mirroring
// tb_sfp_1000base_x_pcs.sv's own inject_err).
//
// gth_clk_o is generated internally as gtrefclk_p_i/2 (a plain fabric
// clock divider) -- gth_sfp_wrapper.sv's real gth_clk_o instead comes
// from the GT's own TXUSRCLK2, so this is only rate-equivalent, not the
// same clock source; fine for digital-logic-only simulation, since
// nothing here exercises the real CPLL/CDR.

module gth_sfp_sim_model #(
  parameter int LOOPBACK_DELAY_CYCLES = 3
) (
  input  logic freerun_clk_i, // unused (see header) -- kept for a
                                // drop-in-identical port list with
                                // gth_sfp_wrapper.sv
  input  logic rst_n,

  input  logic gtrefclk_p_i,  // used as this model's own clock source
  input  logic gtrefclk_n_i,  // unused (see header)

  output logic txp_o,         // unused placeholders (see header)
  output logic txn_o,
  input  logic rxp_i,
  input  logic rxn_i,

  output logic gth_clk_o,
  output logic gth_rst_n_o,

  input  logic [15:0] txdata_i,
  input  logic [1:0]  txcharisk_i,

  output logic [15:0] rxdata_o,
  output logic [1:0]  rxcharisk_o,
  output logic [1:0]  rxdisperr_o,
  output logic [1:0]  rxnotintable_o,

  output logic gtpowergood_o,
  output logic tx_resetdone_o,
  output logic rx_resetdone_o,

  // sim-only test hooks, no counterpart on gth_sfp_wrapper.sv -- a
  // testbench instantiating this model directly may drive them; a
  // testbench swapping between this model and the real wrapper should
  // tie force_rx_error_i=0 so both build the same way
  input  logic force_rx_error_i
);

  assign txp_o = 1'b0;
  assign txn_o = 1'b1;
  wire unused_rx_pins = rxp_i ^ rxn_i; // silence lint, no functional use

  // gth_clk_o: plain divide-by-2 of gtrefclk_p_i, matching this
  // project's testbenches' own generation of a gth_clk-class signal from
  // whatever's available (see e.g. tb_switch_top.sv's gth_clk_sfp)
  logic gth_clk_q;
  always_ff @(posedge gtrefclk_p_i or negedge rst_n) begin
    if (!rst_n) gth_clk_q <= 1'b0;
    else        gth_clk_q <= ~gth_clk_q;
  end
  assign gth_clk_o = gth_clk_q;

  // reset/status: no real sequencing to model -- power-good and both
  // resetdone flags simply track rst_n after a couple of gth_clk cycles,
  // and gth_rst_n_o follows directly
  logic [1:0] rst_sync_q;
  always_ff @(posedge gth_clk_o or negedge rst_n) begin
    if (!rst_n) rst_sync_q <= 2'b00;
    else        rst_sync_q <= {rst_sync_q[0], 1'b1};
  end
  assign gth_rst_n_o    = rst_sync_q[1];
  assign gtpowergood_o  = rst_n;
  assign tx_resetdone_o = rst_sync_q[1];
  assign rx_resetdone_o = rst_sync_q[1];

  // TX->RX loopback with fixed registered latency
  logic [15:0] data_pipe [0:LOOPBACK_DELAY_CYCLES-1];
  logic [1:0]  k_pipe    [0:LOOPBACK_DELAY_CYCLES-1];

  always_ff @(posedge gth_clk_o or negedge gth_rst_n_o) begin
    if (!gth_rst_n_o) begin
      for (int i = 0; i < LOOPBACK_DELAY_CYCLES; i++) begin
        data_pipe[i] <= '0;
        k_pipe[i]    <= '0;
      end
    end else begin
      data_pipe[0] <= txdata_i;
      k_pipe[0]    <= txcharisk_i;
      for (int i = 1; i < LOOPBACK_DELAY_CYCLES; i++) begin
        data_pipe[i] <= data_pipe[i-1];
        k_pipe[i]    <= k_pipe[i-1];
      end
    end
  end

  assign rxdata_o       = data_pipe[LOOPBACK_DELAY_CYCLES-1];
  assign rxcharisk_o    = k_pipe[LOOPBACK_DELAY_CYCLES-1];
  assign rxdisperr_o    = {2{force_rx_error_i}};
  assign rxnotintable_o = {2{force_rx_error_i}};

endmodule
