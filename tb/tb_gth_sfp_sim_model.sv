// tb_gth_sfp_sim_model.sv
//
// Standalone test of gth_sfp_sim_model.sv (not composed with
// sfp_1000base_x_pcs.sv -- see that model's header for why the exact
// clk<->gth_clk phase relationship a composed system would need isn't
// something this model's own free-running divider guarantees in
// general; sfp_port_top-level clock generation stays testbench-owned,
// as in tb_sfp_port_top.sv).
//
//   A. reset behavior: gtpowergood_o/tx_resetdone_o/rx_resetdone_o/
//      gth_rst_n_o all track rst_n
//   B. TX->RX loopback: a sequence of (data,charisk) words reappears on
//      rxdata_o/rxcharisk_o exactly LOOPBACK_DELAY_CYCLES gth_clk cycles
//      later, in order
//   C. force_rx_error_i drives rxdisperr_o/rxnotintable_o high on both
//      lanes while asserted, low otherwise

`timescale 1ns/1ps

module tb_gth_sfp_sim_model;

  localparam int DELAY = 3;

  logic freerun_clk = 0;
  always #10 freerun_clk = ~freerun_clk;

  logic rst_n = 0;
  logic gtrefclk_p = 0;
  logic gtrefclk_n = 1;
  always #4 begin gtrefclk_p = ~gtrefclk_p; gtrefclk_n = ~gtrefclk_n; end // 125 MHz-class

  logic [15:0] txdata = '0;
  logic [1:0]  txcharisk = '0;
  logic [15:0] rxdata;
  logic [1:0]  rxcharisk, rxdisperr, rxnotintable;
  logic gth_clk, gth_rst_n, gtpowergood, tx_resetdone, rx_resetdone;
  logic force_rx_error = 1'b0;

  gth_sfp_sim_model #(.LOOPBACK_DELAY_CYCLES(DELAY)) dut (
    .freerun_clk_i   (freerun_clk),
    .rst_n           (rst_n),
    .gtrefclk_p_i    (gtrefclk_p),
    .gtrefclk_n_i    (gtrefclk_n),
    .txp_o           (),
    .txn_o           (),
    .rxp_i           (1'b0),
    .rxn_i           (1'b1),
    .gth_clk_o       (gth_clk),
    .gth_rst_n_o     (gth_rst_n),
    .txdata_i        (txdata),
    .txcharisk_i     (txcharisk),
    .rxdata_o        (rxdata),
    .rxcharisk_o     (rxcharisk),
    .rxdisperr_o     (rxdisperr),
    .rxnotintable_o  (rxnotintable),
    .gtpowergood_o   (gtpowergood),
    .tx_resetdone_o  (tx_resetdone),
    .rx_resetdone_o  (rx_resetdone),
    .force_rx_error_i(force_rx_error)
  );

  int errors = 0;

  initial begin
    // ---- test A: reset behavior ----
    // gtpowergood_o tracks rst_n combinationally, checkable immediately;
    // tx_resetdone_o/rx_resetdone_o/gth_rst_n_o are registered and X
    // until the first gth_clk edge, so only gtpowergood_o is meaningful
    // to check pre-reset-release.
    if (gtpowergood !== 1'b0) begin
      $display("FAIL: testA gtpowergood_o not held low during reset");
      errors++;
    end

    #50 rst_n = 1'b1;

    begin
      int timeout;
      timeout = 0;
      while (!gth_rst_n && timeout < 200) begin
        @(posedge gth_clk);
        timeout++;
      end
      if (!gth_rst_n || !gtpowergood || !tx_resetdone || !rx_resetdone) begin
        $display("FAIL: testA status signals never all asserted after reset release");
        errors++;
      end else begin
        $display("PASS: testA gtpowergood/tx_resetdone/rx_resetdone/gth_rst_n_o all asserted after reset release");
      end
    end

    // ---- test B: TX->RX loopback with fixed delay ----
    // Captures rxdata/rxcharisk into a queue every cycle while driving
    // (rather than counting cycles by hand to know exactly when each
    // sent word "should" reappear -- this raw pipe has no per-cycle
    // valid flag, so every cycle produces *some* value from the start),
    // then checks the DELAY-cycle-shifted subsequence against what was
    // sent, the same robust capture-and-compare pattern
    // tb_sfp_1000base_x_pcs.sv itself uses.
    begin
      logic [15:0] sent_data  [0:9];
      logic [1:0]  sent_k     [0:9];
      logic [15:0] cap_data   [$];
      logic [1:0]  cap_k      [$];
      bit ok;
      ok = 1'b1;

      for (int i = 0; i < 10; i++) begin
        sent_data[i] = 16'hA000 + i;
        sent_k[i]    = i[1:0];
      end

      fork
        begin
          for (int i = 0; i < 10; i++) begin
            txdata    <= sent_data[i];
            txcharisk <= sent_k[i];
            @(posedge gth_clk);
          end
          txdata    <= '0;
          txcharisk <= '0;
        end
        begin
          repeat (10 + DELAY) begin
            @(posedge gth_clk);
            cap_data.push_back(rxdata);
            cap_k.push_back(rxcharisk);
          end
        end
      join

      for (int i = 0; i < 10; i++) begin
        if (cap_data[DELAY + i] !== sent_data[i] || cap_k[DELAY + i] !== sent_k[i]) begin
          $display("FAIL: testB word %0d mismatch: got data=%04h k=%01b, expected data=%04h k=%01b",
                    i, cap_data[DELAY + i], cap_k[DELAY + i], sent_data[i], sent_k[i]);
          ok = 1'b0;
        end
      end
      if (ok) $display("PASS: testB TX->RX loopback reproduced all 10 words in order with %0d-cycle delay", DELAY);
      else errors++;
    end

    // ---- test C: error injection ----
    begin
      force_rx_error = 1'b1;
      @(posedge gth_clk);
      @(posedge gth_clk);
      if (rxdisperr !== 2'b11 || rxnotintable !== 2'b11) begin
        $display("FAIL: testC rxdisperr_o/rxnotintable_o not both high while force_rx_error_i asserted");
        errors++;
      end else begin
        force_rx_error = 1'b0;
        @(posedge gth_clk);
        @(posedge gth_clk);
        if (rxdisperr !== 2'b00 || rxnotintable !== 2'b00) begin
          $display("FAIL: testC rxdisperr_o/rxnotintable_o not both low after force_rx_error_i deasserted");
          errors++;
        end else begin
          $display("PASS: testC force_rx_error_i drives and releases rxdisperr_o/rxnotintable_o correctly");
        end
      end
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
