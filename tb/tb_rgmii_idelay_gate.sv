// tb_rgmii_idelay_gate.sv  (Vivado xsim only: uses the real UNISIM primitives)
//
// The real rgmii_gmii_adapter's receive path must stay in reset until its
// IDELAYCTRL reports RDY, and go back into reset when RDY drops (IDELAYCTRL
// reset asserted). Also checks the UG571 Component Mode Reset Sequence order
// (IDELAYE3 reset released before IDELAYCTRL reset) and that the receive path
// is released no sooner than 64 receive clocks after RDY.

`timescale 1ns/1ps

module tb_rgmii_idelay_gate;
  logic gtx = 0, rxc = 0, dref = 0;
  always #4.0 gtx = ~gtx;
  always #4.0 rxc = ~rxc;
  always #1.667 dref = ~dref;   // ~300 MHz IDELAYCTRL reference

  logic gtx_rst_n = 0, idly_rst_n = 0;
  wire  rdy, ovf, und;
  wire [3:0] txd; wire txctl, txc;
  wire [7:0] rxd_o; wire dv, er;

  rgmii_gmii_adapter dut (
    .gtx_clk (gtx), .gtx_rst_n (gtx_rst_n),
    .idelay_refclk_i (dref), .idelay_rst_n_i (idly_rst_n),
    .rgmii_txd_o (txd), .rgmii_tx_ctl_o (txctl), .rgmii_txc_o (txc),
    .rgmii_rxd_i (4'h0), .rgmii_rx_ctl_i (1'b0), .rgmii_rxc_i (rxc),
    .gmii_txd_i (8'h00), .gmii_tx_en_i (1'b0), .gmii_tx_er_i (1'b0),
    .gmii_rxd_o (rxd_o), .gmii_rx_dv_o (dv), .gmii_rx_er_o (er),
    .diag_clk_i (gtx), .diag_rst_n_i (gtx_rst_n), .diag_clr_overflow_i (1'b0), .diag_clr_underrun_i (1'b0),
    .idelay_rdy_o (rdy), .rx_elastic_overflow_o (ovf), .rx_elastic_underrun_o (und));

  int errors = 0;
  int viol = 0;
  // continuous invariant: receive reset released only while RDY is high
  // (RDY dropping asserts the receive reset through a 2-flop synchronizer, so allow a short lag)
  int lag = 0;
  always @(posedge rxc) begin
    if (dut.rxc_rst_n && !rdy) begin lag++; if (lag > 8) viol++; end else lag = 0;
  end

  // order of reset release: watch both reset pins
  time t_dly_rel = 0, t_ctrl_rel = 0, t_rdy = 0, t_rx_rel = 0;
  wire dly_rst  = dut.g_dly_ctl.u_idly.RST;
  wire ctrl_rst = dut.g_idelayctrl.u_idelayctrl.RST;
  always @(negedge dly_rst)  t_dly_rel  = $time;
  always @(negedge ctrl_rst) t_ctrl_rel = $time;
  always @(posedge rdy)      t_rdy      = $time;
  always @(posedge dut.rxc_rst_n) t_rx_rel = $time;

  initial begin
    repeat (20) @(posedge gtx);
    gtx_rst_n = 1;                       // local reset released while IDELAYCTRL still in reset
    repeat (50) @(posedge gtx);
    if (rdy !== 1'b0) begin errors++; $display("FAIL: RDY high while IDELAYCTRL is in reset"); end
    if (dut.rxc_rst_n !== 1'b0) begin errors++; $display("FAIL: receive reset released before RDY"); end

    idly_rst_n = 1;                      // let it calibrate
    wait (rdy === 1'b1);
    repeat (60) @(posedge rxc);
    if (dut.rxc_rst_n !== 1'b0) begin errors++; $display("FAIL: receive released within 60 rxc cycles of RDY"); end
    repeat (60) @(posedge rxc);
    if (dut.rxc_rst_n !== 1'b1) begin errors++; $display("FAIL: receive reset not released after RDY"); end
    $display("INFO: RDY high, receive reset released");
    if (!(t_dly_rel < t_ctrl_rel)) begin errors++; $display("FAIL: IDELAYCTRL reset released (%0t) not after IDELAYE3 reset (%0t)", t_ctrl_rel, t_dly_rel); end
    if (t_rx_rel - t_rdy < 512) begin errors++; $display("FAIL: receive released only %0t after RDY (need >= 64 rxc cycles = 512 ns)", t_rx_rel - t_rdy); end
    $display("INFO: IDELAYE3 rst released %0t, IDELAYCTRL rst released %0t, RDY %0t, receive released %0t", t_dly_rel, t_ctrl_rel, t_rdy, t_rx_rel);

    idly_rst_n = 0;                      // recalibrate: RDY must drop and take the receive path with it
    repeat (30) @(posedge gtx);
    if (rdy !== 1'b0) begin errors++; $display("FAIL: RDY did not drop on IDELAYCTRL reset"); end
    if (dut.rxc_rst_n !== 1'b0) begin errors++; $display("FAIL: receive reset not re-asserted when RDY dropped"); end

    idly_rst_n = 1; wait (rdy === 1'b1); repeat (120) @(posedge rxc);
    if (dut.rxc_rst_n !== 1'b1) begin errors++; $display("FAIL: receive reset not released on second calibration"); end
    if (viol != 0) begin errors++; $display("FAIL: %0d cycles with receive reset released while RDY low", viol); end
    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
  initial begin #200000; $display("FAIL: timeout (RDY never rose?)"); $finish; end
endmodule
