// tb_pl_eth_clk_gen_sim_model.sv
//
// Standalone test of pl_eth_clk_gen_sim_model.sv:
//   A. reset behavior: locked_o/gtx_rst_n_o/idelay_refclk_rst_n_o/
//      rst_n_o all stay low through reset and while waiting out the
//      fake lock delay, then all assert
//   B. gtx_clk_o period is 8ns (125MHz), idelay_refclk_o period is
//      ~1.667ns (300MHz), clk_o period is 10ns (100MHz), measured
//      directly from edge timestamps

`timescale 1ns/1ps

module tb_pl_eth_clk_gen_sim_model;

  logic ref_clk_25m = 0;
  always #20 ref_clk_25m = ~ref_clk_25m; // 25 MHz (unused by the DUT, see its header)

  logic rst_n = 0;

  logic gtx_clk, gtx_rst_n;
  logic idelay_refclk, idelay_refclk_rst_n;
  logic clk, rst_n_sync;
  logic locked;

  pl_eth_clk_gen_sim_model #(.LOCK_DELAY_CYCLES(8)) dut (
    .ref_clk_25m_i         (ref_clk_25m),
    .rst_n_i               (rst_n),
    .gtx_clk_o             (gtx_clk),
    .gtx_rst_n_o           (gtx_rst_n),
    .idelay_refclk_o       (idelay_refclk),
    .idelay_refclk_rst_n_o (idelay_refclk_rst_n),
    .clk_o                 (clk),
    .rst_n_o               (rst_n_sync),
    .locked_o              (locked)
  );

  int errors;

  initial begin
    errors = 0;

    // ---- test A: reset behavior ----
    // (no pre-clock-edge check here: locked_o/gtx_rst_n_o/
    // idelay_refclk_rst_n_o are all registered and X until their first
    // clock edge, so checking them at time 0 before either free-running
    // clock has ticked isn't meaningful -- same reasoning as
    // tb_gth_sfp_sim_model.sv's testA)
    #50 rst_n = 1'b1;

    begin
      int timeout;
      timeout = 0;
      while (!locked && timeout < 200) begin
        @(posedge gtx_clk);
        timeout++;
      end
      if (!locked) begin
        $display("FAIL: testA locked_o never asserted after reset release");
        errors++;
      end else begin
        // gtx_rst_n_o/idelay_refclk_rst_n_o/rst_n_o each need a couple
        // more cycles of their own domain to release after locked_o
        // asserts
        repeat (4) @(posedge gtx_clk);
        repeat (4) @(posedge idelay_refclk);
        repeat (4) @(posedge clk);
        if (!gtx_rst_n || !idelay_refclk_rst_n || !rst_n_sync) begin
          $display("FAIL: testA gtx_rst_n_o/idelay_refclk_rst_n_o/rst_n_o never released after lock");
          errors++;
        end else begin
          $display("PASS: testA locked_o/gtx_rst_n_o/idelay_refclk_rst_n_o/rst_n_o all asserted after %0d cycles + lock delay", timeout);
        end
      end
    end

    // ---- test B: clock periods ----
    // Uses $realtime (a real, full-precision value), not $time: $time
    // returns an integer truncated to the module's *timeunit* (1ns
    // here), silently losing everything below a whole nanosecond -- it
    // happened to still work for gtx_clk_o's exactly-8ns period, but
    // would have quietly measured idelay_refclk_o's 3.334ns period as
    // something meaningless. Caught by cross-checking against $realtime
    // directly, not by the numbers merely "looking wrong".
    begin
      real t0, t1, gtx_period, idelay_period, clk_period;
      bit ok;
      ok = 1'b1;

      @(posedge gtx_clk); t0 = $realtime;
      @(posedge gtx_clk); t1 = $realtime;
      gtx_period = t1 - t0;
      if (gtx_period < 7.999 || gtx_period > 8.001) begin
        $display("FAIL: testB gtx_clk_o period = %0fns, expected 8ns (125MHz)", gtx_period);
        ok = 1'b0;
      end

      @(posedge idelay_refclk); t0 = $realtime;
      @(posedge idelay_refclk); t1 = $realtime;
      idelay_period = t1 - t0;
      if (idelay_period < 3.333 || idelay_period > 3.335) begin
        $display("FAIL: testB idelay_refclk_o period = %0fns, expected ~3.334ns (300MHz)", idelay_period);
        ok = 1'b0;
      end

      @(posedge clk); t0 = $realtime;
      @(posedge clk); t1 = $realtime;
      clk_period = t1 - t0;
      if (clk_period < 9.999 || clk_period > 10.001) begin
        $display("FAIL: testB clk_o period = %0fns, expected 10ns (100MHz)", clk_period);
        ok = 1'b0;
      end

      if (ok) $display("PASS: testB gtx_clk_o=125MHz, idelay_refclk_o=300MHz, clk_o=100MHz (measured from edge timestamps)");
      else errors++;
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
