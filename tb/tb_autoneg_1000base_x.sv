// tb_autoneg_1000base_x.sv
//
// Two independent sfp_1000base_x_pcs instances cross-wired at the GTH-
// parallel-interface boundary (A's txdata_o -> B's rxdata_i and vice
// versa) -- real link partners, not the self-loopback tb_sfp_1000base_x_
// pcs.sv already uses for its own (non-AN-focused) tests. This is the
// test that actually exercises Clause 37 auto-negotiation as a two-party
// protocol: self-loopback trivially "agrees" with itself even if the
// ACK/consistency logic were broken in a way that only shows up between
// two genuinely independent state machines.
//
// Both instances share one clk/gth_clk pair (a simplification: real
// separate SFP modules would have independent GTH/refclk domains, but
// this DUT's own gearbox already assumes gth_clk is a fixed clk/2 phase
// relationship, not an independent oscillator -- modeling that per
// instance isn't needed to validate the AN wire protocol itself).
//
//   A. from reset, both sides converge to an_link_up_o, resolved
//      duplex_full/pause/remote_fault matching (both sides advertise
//      the same default ability here)
//   B. a GMII frame from A reaches B byte-for-byte after link-up
//   C. a GMII frame from B reaches A byte-for-byte (other direction)
//   D. one side's sync_ok is corrupted (injected RXNOTINTABLE) -> both
//      sides' an_link_up_o eventually drop and re-negotiation restarts
//      once corruption stops -- exercises the restart-on-sync-loss path
//      the pipeline-latency-echo bug (see autoneg_1000base_x.sv's
//      S_IDLE_DETECT restart-condition comment) was found in

`timescale 1ns/1ps

module tb_autoneg_1000base_x;

  logic clk = 0;
  logic rst_n = 0;
  always #4 clk = ~clk;

  // see tb_sfp_1000base_x_pcs.sv's header for why gth_clk's first edge
  // is placed at the midpoint of the packed word's valid window, not on
  // a clk edge
  logic gth_clk = 0;
  logic gth_rst_n = 0;
  initial begin
    #16 gth_clk = 1;
    forever #8 gth_clk = ~gth_clk;
  end

  // ---- side A ----
  logic [7:0] a_gmii_txd = 0;
  logic       a_gmii_tx_en = 0, a_gmii_tx_er = 0;
  logic [7:0] a_gmii_rxd;
  logic       a_gmii_rx_dv, a_gmii_rx_er;
  logic [15:0] a_txdata, a_rxdata;
  logic [1:0]  a_txcharisk, a_rxcharisk;
  logic [1:0]  a_rxdisperr = 2'b00, a_rxnotintable = 2'b00;
  logic        a_sync_ok, a_an_link_up, a_an_duplex_full, a_an_remote_fault;
  logic [1:0]  a_an_pause;

  // ---- side B ----
  logic [7:0] b_gmii_txd = 0;
  logic       b_gmii_tx_en = 0, b_gmii_tx_er = 0;
  logic [7:0] b_gmii_rxd;
  logic       b_gmii_rx_dv, b_gmii_rx_er;
  logic [15:0] b_txdata, b_rxdata;
  logic [1:0]  b_txcharisk, b_rxcharisk;
  logic [1:0]  b_rxdisperr = 2'b00;
  logic [1:0]  b_rxnotintable;
  logic        b_sync_ok, b_an_link_up, b_an_duplex_full, b_an_remote_fault;
  logic [1:0]  b_an_pause;

  // cross-wire: A's TX -> B's RX, B's TX -> A's RX
  assign b_rxdata      = a_txdata;
  assign b_rxcharisk   = a_txcharisk;
  assign a_rxdata      = b_txdata;
  assign a_rxcharisk   = b_txcharisk;

  // test D injects errors on B's RX (i.e. corrupts what A sent to B)
  logic inject_err = 1'b0;
  assign b_rxnotintable = {2{inject_err}};

  sfp_1000base_x_pcs dut_a (
    .clk (clk), .rst_n (rst_n), .gth_clk (gth_clk), .gth_rst_n (gth_rst_n),
    .gmii_txd_i (a_gmii_txd), .gmii_tx_en_i (a_gmii_tx_en), .gmii_tx_er_i (a_gmii_tx_er),
    .gmii_rxd_o (a_gmii_rxd), .gmii_rx_dv_o (a_gmii_rx_dv), .gmii_rx_er_o (a_gmii_rx_er),
    .txdata_o (a_txdata), .txcharisk_o (a_txcharisk),
    .rxdata_i (a_rxdata), .rxcharisk_i (a_rxcharisk),
    .rxdisperr_i (a_rxdisperr), .rxnotintable_i (a_rxnotintable),
    .sync_ok_o (a_sync_ok),
    .an_link_up_o (a_an_link_up), .an_duplex_full_o (a_an_duplex_full),
    .an_pause_o (a_an_pause), .an_remote_fault_o (a_an_remote_fault)
  );

  sfp_1000base_x_pcs dut_b (
    .clk (clk), .rst_n (rst_n), .gth_clk (gth_clk), .gth_rst_n (gth_rst_n),
    .gmii_txd_i (b_gmii_txd), .gmii_tx_en_i (b_gmii_tx_en), .gmii_tx_er_i (b_gmii_tx_er),
    .gmii_rxd_o (b_gmii_rxd), .gmii_rx_dv_o (b_gmii_rx_dv), .gmii_rx_er_o (b_gmii_rx_er),
    .txdata_o (b_txdata), .txcharisk_o (b_txcharisk),
    .rxdata_i (b_rxdata), .rxcharisk_i (b_rxcharisk),
    .rxdisperr_i (b_rxdisperr), .rxnotintable_i (b_rxnotintable),
    .sync_ok_o (b_sync_ok),
    .an_link_up_o (b_an_link_up), .an_duplex_full_o (b_an_duplex_full),
    .an_pause_o (b_an_pause), .an_remote_fault_o (b_an_remote_fault)
  );

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  byte a_rxd_bytes[$];
  byte b_rxd_bytes[$];

  always_ff @(posedge clk) begin
    if (a_gmii_rx_dv) a_rxd_bytes.push_back(byte'(a_gmii_rxd));
    if (b_gmii_rx_dv) b_rxd_bytes.push_back(byte'(b_gmii_rxd));
  end

  task automatic drive_frame_a(input byte payload[]);
    byte data[];
    int n;
    n = 8 + payload.size();
    data = new[n];
    for (int i = 0; i < 7; i++) data[i] = 8'h55;
    data[7] = 8'hD5;
    for (int i = 0; i < payload.size(); i++) data[8+i] = payload[i];
    for (int i = 0; i < n; i++) begin
      a_gmii_txd   <= data[i];
      a_gmii_tx_en <= 1'b1;
      @(posedge clk);
    end
    a_gmii_tx_en <= 1'b0;
    @(posedge clk);
  endtask

  task automatic drive_frame_b(input byte payload[]);
    byte data[];
    int n;
    n = 8 + payload.size();
    data = new[n];
    for (int i = 0; i < 7; i++) data[i] = 8'h55;
    data[7] = 8'hD5;
    for (int i = 0; i < payload.size(); i++) data[8+i] = payload[i];
    for (int i = 0; i < n; i++) begin
      b_gmii_txd   <= data[i];
      b_gmii_tx_en <= 1'b1;
      @(posedge clk);
    end
    b_gmii_tx_en <= 1'b0;
    @(posedge clk);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst_n     = 1'b1;
    gth_rst_n = 1'b1;

    // ---- test A: both sides negotiate up ----
    begin
      int timeout;
      timeout = 0;
      while (!(a_an_link_up && b_an_link_up) && timeout < 500) begin
        @(posedge clk);
        timeout++;
      end
      if (!(a_an_link_up && b_an_link_up)) begin
        $display("FAIL: testA not both sides reached an_link_up_o (timeout=%0d, a=%0b b=%0b)",
                  timeout, a_an_link_up, b_an_link_up);
        errors++;
      end else if (a_an_duplex_full !== b_an_duplex_full || a_an_pause !== b_an_pause ||
                   a_an_remote_fault !== 1'b0 || b_an_remote_fault !== 1'b0) begin
        $display("FAIL: testA resolved status mismatch (a: duplex=%0b pause=%0b rf=%0b; b: duplex=%0b pause=%0b rf=%0b)",
                  a_an_duplex_full, a_an_pause, a_an_remote_fault,
                  b_an_duplex_full, b_an_pause, b_an_remote_fault);
        errors++;
      end else begin
        $display("PASS: testA both independent link partners reached an_link_up_o after %0d cycles, resolved status matches", timeout);
      end
    end
    wait_cycles(10);

    // ---- test B: A -> B frame ----
    begin
      byte payload[];
      byte expected[];
      payload = new[16];
      for (int i = 0; i < 16; i++) payload[i] = byte'(8'h60 + i);
      expected = new[23];
      for (int i = 0; i < 6; i++) expected[i] = 8'h55;
      expected[6] = 8'hD5;
      for (int i = 0; i < 16; i++) expected[7+i] = payload[i];

      b_rxd_bytes.delete();
      drive_frame_a(payload);
      wait_cycles(10);

      if (b_rxd_bytes.size() != 23) begin
        $display("FAIL: testB B received %0d bytes, expected 23", b_rxd_bytes.size());
        errors++;
      end else begin
        bit ok = 1'b1;
        for (int i = 0; i < 23; i++) if (b_rxd_bytes[i] !== expected[i]) ok = 1'b0;
        if (ok) $display("PASS: testB frame sent by A reached B byte-for-byte after negotiation");
        else begin
          $display("FAIL: testB content mismatch");
          errors++;
        end
      end
    end

    // ---- test C: B -> A frame ----
    begin
      byte payload[];
      byte expected[];
      payload = new[10];
      for (int i = 0; i < 10; i++) payload[i] = byte'(8'hC0 + i);
      expected = new[17];
      for (int i = 0; i < 6; i++) expected[i] = 8'h55;
      expected[6] = 8'hD5;
      for (int i = 0; i < 10; i++) expected[7+i] = payload[i];

      a_rxd_bytes.delete();
      drive_frame_b(payload);
      wait_cycles(10);

      if (a_rxd_bytes.size() != 17) begin
        $display("FAIL: testC A received %0d bytes, expected 17", a_rxd_bytes.size());
        errors++;
      end else begin
        bit ok = 1'b1;
        for (int i = 0; i < 17; i++) if (a_rxd_bytes[i] !== expected[i]) ok = 1'b0;
        if (ok) $display("PASS: testC frame sent by B reached A byte-for-byte after negotiation");
        else begin
          $display("FAIL: testC content mismatch");
          errors++;
        end
      end
    end

    // ---- test D: sync loss on B's RX drops both sides' link, then
    // re-negotiation completes once corruption stops ----
    begin
      int timeout;
      inject_err = 1'b1;
      timeout = 0;
      while ((a_an_link_up || b_an_link_up) && timeout < 200) begin
        @(posedge clk);
        timeout++;
      end
      if (a_an_link_up || b_an_link_up) begin
        $display("FAIL: testD an_link_up_o never dropped under sustained corruption (a=%0b b=%0b)",
                  a_an_link_up, b_an_link_up);
        errors++;
      end else begin
        $display("PASS: testD both sides' an_link_up_o dropped after %0d cycles of sustained corruption", timeout);
      end

      inject_err = 1'b0;
      timeout = 0;
      while (!(a_an_link_up && b_an_link_up) && timeout < 500) begin
        @(posedge clk);
        timeout++;
      end
      if (!(a_an_link_up && b_an_link_up)) begin
        $display("FAIL: testD both sides never re-negotiated an_link_up_o after corruption stopped");
        errors++;
      end else begin
        $display("PASS: testD both sides re-negotiated an_link_up_o %0d cycles after corruption stopped", timeout);
      end
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
