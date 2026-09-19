// tb_sfp_sideband.sv
//
// SFP sideband control with the timers scaled down (CLK_HZ=10000 => 10 clocks per ms).
//   A. reset: laser off (TX_DISABLE=1) while the module is absent
//   B. insertion: stays off through debounce + settle, then enables
//   C. software force bit disables/enables the laser
//   D. TX_FAULT: laser drops for the hold time, comes back, fault_seen and the
//      fault count record it; a fault that clears after restart returns to RUN
//   E. persistent fault: after MAX_RETRIES the laser stays off (lockout), a
//      clear-lockout write re-enables after settle
//   F. removal: laser off immediately, removal recorded
//   G. bounce on MOD_ABS shorter than the debounce time is ignored

`timescale 1ns/1ps

module tb_sfp_sideband;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  logic mod_abs = 1, tx_fault = 0, los = 0;
  wire  tx_dis;
  logic force_dis = 0, clr_fault = 0, clr_removed = 0, clr_lockout = 0;
  wire [15:0] st;

  sfp_sideband #(.CLK_HZ(10_000), .DEBOUNCE_MS(3), .SETTLE_MS(20), .HOLD_MS(2), .RESTART_MS(15),
                 .HEALTHY_MS(200), .MAX_RETRIES(3)) dut (
    .clk (clk), .rst_n (rst_n), .mod_abs_i (mod_abs), .tx_fault_i (tx_fault), .los_i (los),
    .tx_disable_o (tx_dis), .force_disable_i (force_dis),
    .clr_fault_seen_i (clr_fault), .clr_removed_seen_i (clr_removed), .clr_lockout_i (clr_lockout),
    .status_o (st));

  int errors = 0;
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("FAIL: %s (t=%0t st=%h tx_dis=%b)", m, $time, st, tx_dis); end endtask
  task automatic ms(input int n); repeat (n * 10) @(posedge clk); endtask
  task automatic p_fault();   @(posedge clk); clr_fault <= 1;   @(posedge clk); clr_fault <= 0;   endtask
  task automatic p_removed(); @(posedge clk); clr_removed <= 1; @(posedge clk); clr_removed <= 0; endtask
  task automatic p_lockout(); @(posedge clk); clr_lockout <= 1; @(posedge clk); clr_lockout <= 0; endtask

  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    ms(10); check(tx_dis === 1, "A: off while absent");

    // B
    mod_abs = 0;
    ms(2); check(tx_dis === 1, "B: still off during debounce");
    ms(10); check(tx_dis === 1, "B: still off during settle");
    ms(30); check(tx_dis === 0, "B: enabled after settle"); check(st[0] === 0, "B: mod_abs status");

    // C
    force_dis = 1; ms(1); check(tx_dis === 1, "C: force disables");
    force_dis = 0; ms(1); check(tx_dis === 0, "C: released");

    // D: fault for a while, cleared by the module during the hold
    los = 1; ms(1); check(st[1] === 1, "LOS reported"); los = 0;
    tx_fault = 1; ms(3); check(tx_dis === 1, "D: laser off on fault");
    tx_fault = 0; ms(3);
    check(st[5] === 1, "D: fault_seen set"); check(st[15:8] === 8'd1, "D: fault count 1");
    ms(25); check(tx_dis === 0, "D: laser back after hold+restart");
    p_fault(); ms(1); check(st[5] === 0, "D: fault_seen cleared");

    // E: persistent fault
    tx_fault = 1; ms(40); check(st[15:8] >= 2, "E: fault count grows");
    ms(120); check(st[4] === 1, "E: lockout"); check(tx_dis === 1, "E: laser stays off in lockout");
    ms(50); check(tx_dis === 1, "E: still off");
    tx_fault = 0; p_lockout(); ms(5); check(st[4] === 0, "E: lockout cleared");
    ms(40); check(tx_dis === 0, "E: re-enabled after settle");

    // F: removal
    mod_abs = 1; ms(6); check(tx_dis === 1, "F: off after removal"); check(st[6] === 1, "F: removal recorded");
    p_removed(); ms(1); check(st[6] === 0, "F: removal flag cleared");

    // G: short bounce ignored
    mod_abs = 0; ms(40); check(tx_dis === 0, "G: re-inserted and settled");
    mod_abs = 1; ms(1); mod_abs = 0; ms(6); check(tx_dis === 0, "G: 1 ms bounce ignored");

    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
endmodule
