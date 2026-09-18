// tb_sfp_1000base_x_pcs.sv
//
// Self-checking digital loopback test for sfp_1000base_x_pcs.sv: TX
// codec output wired straight back into the RX side (no real GTH/SFP/
// fiber in the loop -- this validates the hand-written PCS logic itself,
// not real transceiver/optical behavior).
//
//   A. from reset, idle-only traffic -> sync_ok_o asserts within a
//      reasonable number of cycles
//   B. one full GMII frame (standard preamble+SFD+payload) looped back
//      -> reproduced byte-for-byte, rx_dv timing matches
//   C. a second frame immediately after -> confirms TX/RX/sync state all
//      reset cleanly between frames
//   D. tx_er asserted mid-frame -> rx_er observed at the corresponding
//      received byte position, frame still completes
//   E. injected RXNOTINTABLE errors during idle -> sync_ok_o eventually
//      drops (exercises the leaky error counter, otherwise never
//      touched by A-D), then re-acquires once the corruption stops

`timescale 1ns/1ps

module tb_sfp_1000base_x_pcs;

  logic clk = 0;
  logic rst_n = 0;
  always #4 clk = ~clk; // 125 MHz-equivalent for simulation purposes

  logic [7:0] gmii_txd;
  logic       gmii_tx_en;
  logic       gmii_tx_er;
  logic [7:0] gmii_rxd;
  logic       gmii_rx_dv;
  logic       gmii_rx_er;

  logic [7:0] txdata;
  logic       txcharisk;

  logic [7:0] rxdata;
  logic       rxcharisk;
  logic       rxdisperr;
  logic       rxnotintable;

  logic       sync_ok;

  // loopback, with error-injection override on the RX side for test E
  logic inject_err = 1'b0;
  assign rxdata         = txdata;
  assign rxcharisk      = txcharisk;
  assign rxdisperr      = 1'b0;
  assign rxnotintable   = inject_err;

  sfp_1000base_x_pcs dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .gmii_txd_i      (gmii_txd),
    .gmii_tx_en_i    (gmii_tx_en),
    .gmii_tx_er_i    (gmii_tx_er),
    .gmii_rxd_o      (gmii_rxd),
    .gmii_rx_dv_o    (gmii_rx_dv),
    .gmii_rx_er_o    (gmii_rx_er),
    .txdata_o        (txdata),
    .txcharisk_o     (txcharisk),
    .rxdata_i        (rxdata),
    .rxcharisk_i     (rxcharisk),
    .rxdisperr_i     (rxdisperr),
    .rxnotintable_i  (rxnotintable),
    .sync_ok_o       (sync_ok)
  );

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // ---- capture RX side ----
  byte rxd_bytes[$];
  int  rxd_er_idx[$]; // indices (within rxd_bytes) where rx_er was seen

  task automatic cap_reset();
    rxd_bytes.delete();
    rxd_er_idx.delete();
  endtask

  always_ff @(posedge clk) begin
    if (gmii_rx_dv) begin
      if (gmii_rx_er) rxd_er_idx.push_back(rxd_bytes.size());
      rxd_bytes.push_back(byte'(gmii_rxd));
    end
  end

  // drive one GMII frame: standard 7x0x55 preamble + 0xD5 SFD + payload.
  // err_byte_idx (within payload, -1 = none) asserts tx_er for that cycle.
  task automatic drive_frame(input byte payload[], input int err_byte_idx);
    byte data[];
    int n;
    n = 8 + payload.size();
    data = new[n];
    for (int i = 0; i < 7; i++) data[i] = 8'h55;
    data[7] = 8'hD5;
    for (int i = 0; i < payload.size(); i++) data[8+i] = payload[i];

    for (int i = 0; i < n; i++) begin
      gmii_txd   <= data[i];
      gmii_tx_en <= 1'b1;
      gmii_tx_er <= (err_byte_idx >= 0) && (i == (8 + err_byte_idx));
      @(posedge clk);
    end
    gmii_tx_en <= 1'b0;
    gmii_tx_er <= 1'b0;
    @(posedge clk);
  endtask

  initial begin
    gmii_txd   = '0;
    gmii_tx_en = 1'b0;
    gmii_tx_er = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // ---- test A: sync acquisition from idle ----
    begin
      int timeout;
      timeout = 0;
      while (!sync_ok && timeout < 200) begin
        @(posedge clk);
        timeout++;
      end
      if (!sync_ok) begin
        $display("FAIL: testA sync_ok_o never asserted (timeout=%0d)", timeout);
        errors++;
      end else begin
        $display("PASS: testA sync_ok_o asserted after %0d cycles of idle", timeout);
      end
    end
    wait_cycles(10);

    // ---- test B: one full frame ----
    begin
      byte payload[];
      byte expected[];
      payload = new[20];
      for (int i = 0; i < 20; i++) payload[i] = byte'(i + 8'h10);
      // RX reconstructs 6x0x55+SFD (7 bytes), not the full 8-byte
      // preamble -- /S/ itself already stood in for the first preamble
      // byte on the wire, so only 7 more preamble-ish code groups
      // actually follow it (see gmii_1000base_x_rx.sv's header comment).
      expected = new[27];
      for (int i = 0; i < 6; i++) expected[i] = 8'h55;
      expected[6] = 8'hD5;
      for (int i = 0; i < 20; i++) expected[7+i] = payload[i];

      cap_reset();
      drive_frame(payload, -1);
      wait_cycles(10);

      if (rxd_bytes.size() != 27) begin
        $display("FAIL: testB received %0d bytes, expected 27", rxd_bytes.size());
        errors++;
      end else begin
        bit ok = 1'b1;
        for (int i = 0; i < 27; i++) if (rxd_bytes[i] !== expected[i]) ok = 1'b0;
        if (rxd_er_idx.size() != 0) ok = 1'b0;
        if (ok) $display("PASS: testB frame reproduced exactly (preamble+SFD+20B payload), no errors flagged");
        else begin
          $display("FAIL: testB content mismatch or unexpected rx_er");
          errors++;
        end
      end
    end

    // ---- test C: a second frame right after ----
    begin
      byte payload[];
      byte expected[];
      payload = new[12];
      for (int i = 0; i < 12; i++) payload[i] = byte'(8'hA0 + i);
      expected = new[19];
      for (int i = 0; i < 6; i++) expected[i] = 8'h55;
      expected[6] = 8'hD5;
      for (int i = 0; i < 12; i++) expected[7+i] = payload[i];

      cap_reset();
      drive_frame(payload, -1);
      wait_cycles(10);

      if (rxd_bytes.size() != 19) begin
        $display("FAIL: testC received %0d bytes, expected 19", rxd_bytes.size());
        errors++;
      end else begin
        bit ok = 1'b1;
        for (int i = 0; i < 19; i++) if (rxd_bytes[i] !== expected[i]) ok = 1'b0;
        if (ok) $display("PASS: testC second back-to-back frame reproduced exactly");
        else begin
          $display("FAIL: testC content mismatch");
          errors++;
        end
      end
    end

    // ---- test D: tx_er mid-frame ----
    begin
      byte payload[];
      payload = new[16];
      for (int i = 0; i < 16; i++) payload[i] = byte'(8'h30 + i);

      cap_reset();
      drive_frame(payload, 5); // error on payload byte index 5
      wait_cycles(10);

      if (rxd_bytes.size() != 23) begin // 7 preamble/SFD + 16 payload
        $display("FAIL: testD received %0d bytes, expected 23", rxd_bytes.size());
        errors++;
      end else if (rxd_er_idx.size() != 1 || rxd_er_idx[0] != 7 + 5) begin
        $display("FAIL: testD rx_er not observed at the expected byte position (got %0d entries)", rxd_er_idx.size());
        errors++;
      end else begin
        $display("PASS: testD tx_er propagated to rx_er at the correct byte position, frame still completed");
      end
    end

    // ---- test E: sustained RX corruption drops sync, then re-acquires ----
    begin
      int timeout;
      inject_err = 1'b1;
      timeout = 0;
      while (sync_ok && timeout < 200) begin
        @(posedge clk);
        timeout++;
      end
      if (sync_ok) begin
        $display("FAIL: testE sync_ok_o never dropped under sustained corruption");
        errors++;
      end else begin
        $display("PASS: testE sync_ok_o dropped after %0d cycles of sustained corruption", timeout);
      end

      inject_err = 1'b0;
      timeout = 0;
      while (!sync_ok && timeout < 200) begin
        @(posedge clk);
        timeout++;
      end
      if (!sync_ok) begin
        $display("FAIL: testE sync_ok_o never re-acquired after corruption stopped");
        errors++;
      end else begin
        $display("PASS: testE sync_ok_o re-acquired %0d cycles after corruption stopped", timeout);
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
