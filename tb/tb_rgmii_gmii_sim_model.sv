// tb_rgmii_gmii_sim_model.sv
//
// Self-checking digital loopback test for rgmii_gmii_sim_model.sv (the
// RGMII pins are wired straight back on themselves -- no real PHY/cable
// in the loop, same strategy as every other loopback test in this
// project). Validates the RGMII v2.0 nibble/TX_CTL encode-decode logic
// itself, not real DDR I/O timing (see that model's header for what it
// does and doesn't model, and rgmii_gmii_adapter.sv's header for the
// real, primitive-based version this stands in for).
//
//   A. one GMII frame -> reproduced byte-for-byte on the RX side
//   B. a second frame immediately after -> confirms TX/RX state resets
//      cleanly between frames
//   C. gmii_tx_er_i asserted mid-frame -> gmii_rx_er_o observed at the
//      corresponding byte, frame still completes

`timescale 1ns/1ps

module tb_rgmii_gmii_sim_model;

  logic gtx_clk = 0;
  logic gtx_rst_n = 0;
  always #4 gtx_clk = ~gtx_clk; // 125 MHz-equivalent

  logic [7:0] gmii_txd = 0;
  logic       gmii_tx_en = 0;
  logic       gmii_tx_er = 0;
  logic [7:0] gmii_rxd;
  logic       gmii_rx_dv;
  logic       gmii_rx_er;

  logic [3:0] rgmii_txd;
  logic       rgmii_tx_ctl;
  logic       rgmii_txc;
  logic [3:0] rgmii_rxd;
  logic       rgmii_rx_ctl;
  logic       rgmii_rxc;

  // loopback, no real PHY/cable in the loop. A nonzero delay is required
  // (zero-delay would make rgmii_rxc_i's edge and rgmii_rxd_i/rx_ctl_i's
  // transition the exact same simulation event as gtx_clk's own edge,
  // an avoidable same-instant race); a small clock/data skew is used
  // here as the more realistic choice, matching how a real cable+PHY
  // never has zero clock-to-data skew either. This delay was NOT what
  // fixed the real bugs hit while bringing this testbench up -- both
  // lived in the DUT itself (a same-edge RX combine race and a same-
  // edge TX stimulus race, see rgmii_gmii_sim_model.sv's RX section and
  // drive_frame's own comment below) and reproduced identically across
  // several different delay values tried here, including a uniform one,
  // before being traced to their real cause with $strobe-based tracing.
  assign #1 rgmii_rxd    = rgmii_txd;
  assign #1 rgmii_rx_ctl = rgmii_tx_ctl;
  assign #3 rgmii_rxc    = rgmii_txc;

  rgmii_gmii_sim_model dut (
    .gtx_clk         (gtx_clk),
    .gtx_rst_n       (gtx_rst_n),
    .idelay_refclk_i (1'b0),
    .idelay_rst_n_i  (1'b1),
    .rgmii_txd_o     (rgmii_txd),
    .rgmii_tx_ctl_o  (rgmii_tx_ctl),
    .rgmii_txc_o     (rgmii_txc),
    .rgmii_rxd_i     (rgmii_rxd),
    .rgmii_rx_ctl_i  (rgmii_rx_ctl),
    .rgmii_rxc_i     (rgmii_rxc),
    .gmii_txd_i      (gmii_txd),
    .gmii_tx_en_i    (gmii_tx_en),
    .gmii_tx_er_i    (gmii_tx_er),
    .gmii_rxd_o      (gmii_rxd),
    .gmii_rx_dv_o    (gmii_rx_dv),
    .gmii_rx_er_o    (gmii_rx_er)
  );

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge gtx_clk);
  endtask

  byte rxd_bytes[$];
  int  rxd_er_idx[$];

  task automatic cap_reset();
    rxd_bytes.delete();
    rxd_er_idx.delete();
  endtask

  always_ff @(posedge gtx_clk) begin
    if (gmii_rx_dv) begin
      if (gmii_rx_er) rxd_er_idx.push_back(rxd_bytes.size());
      rxd_bytes.push_back(byte'(gmii_rxd));
    end
  end

  // Drives gmii_txd/tx_en/tx_er right after a negedge, not right after
  // the posedge that samples the PREVIOUS byte -- that gives each value
  // a full half-cycle of margin before the DUT's own next posedge, not
  // zero margin. The DUT's TX side reads these directly, unregistered,
  // in *both* its posedge (rise) and negedge (fall) blocks (see
  // rgmii_gmii_sim_model.sv's header); setting them via NBA immediately
  // after the very posedge that block also samples on gave the posedge
  // reader the stale (pre-update) value while the later negedge reader
  // already saw the new one -- a spurious half-transition at every
  // frame start/end, caught by $strobe-based tracing back to this
  // testbench's own stimulus timing, not a DUT bug.
  task automatic drive_frame(input byte payload[], input int err_byte_idx);
    @(negedge gtx_clk);
    for (int i = 0; i < payload.size(); i++) begin
      gmii_txd   <= payload[i];
      gmii_tx_en <= 1'b1;
      gmii_tx_er <= (err_byte_idx >= 0) && (i == err_byte_idx);
      @(posedge gtx_clk);
      @(negedge gtx_clk);
    end
    gmii_tx_en <= 1'b0;
    gmii_tx_er <= 1'b0;
    @(posedge gtx_clk);
  endtask

  initial begin
    repeat (5) @(posedge gtx_clk);
    gtx_rst_n = 1'b1;
    wait_cycles(10);

    // ---- test A: one frame ----
    begin
      byte payload[];
      bit ok;
      ok = 1'b1;
      payload = new[20];
      for (int i = 0; i < 20; i++) payload[i] = byte'(i + 8'h10);

      cap_reset();
      drive_frame(payload, -1);
      wait_cycles(10);

      if (rxd_bytes.size() != 20) begin
        $display("FAIL: testA received %0d bytes, expected 20", rxd_bytes.size());
        errors++;
      end else begin
        for (int i = 0; i < 20; i++) if (rxd_bytes[i] !== payload[i]) ok = 1'b0;
        if (rxd_er_idx.size() != 0) ok = 1'b0;
        if (ok) $display("PASS: testA frame reproduced exactly (20B), no errors flagged");
        else begin
          $display("FAIL: testA content mismatch or unexpected rx_er");
          errors++;
        end
      end
    end

    // ---- test B: a second frame right after ----
    begin
      byte payload[];
      bit ok;
      ok = 1'b1;
      payload = new[12];
      for (int i = 0; i < 12; i++) payload[i] = byte'(8'hA0 + i);

      cap_reset();
      drive_frame(payload, -1);
      wait_cycles(10);

      if (rxd_bytes.size() != 12) begin
        $display("FAIL: testB received %0d bytes, expected 12", rxd_bytes.size());
        errors++;
      end else begin
        for (int i = 0; i < 12; i++) if (rxd_bytes[i] !== payload[i]) ok = 1'b0;
        if (ok) $display("PASS: testB second back-to-back frame reproduced exactly");
        else begin
          $display("FAIL: testB content mismatch");
          errors++;
        end
      end
    end

    // ---- test C: tx_er mid-frame ----
    begin
      byte payload[];
      payload = new[16];
      for (int i = 0; i < 16; i++) payload[i] = byte'(8'h30 + i);

      cap_reset();
      drive_frame(payload, 5); // error on byte index 5
      wait_cycles(10);

      if (rxd_bytes.size() != 16) begin
        $display("FAIL: testC received %0d bytes, expected 16", rxd_bytes.size());
        errors++;
      end else if (rxd_er_idx.size() != 1 || rxd_er_idx[0] != 5) begin
        $display("FAIL: testC rx_er not observed at the expected byte position (got %0d entries)", rxd_er_idx.size());
        errors++;
      end else begin
        $display("PASS: testC tx_er propagated to rx_er at the correct byte position, frame still completed");
      end
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #1_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
