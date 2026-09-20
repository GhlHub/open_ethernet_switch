// tb_mac_addr_table.sv
//
// Self-checking smoke test for mac_addr_table_top:
//   1. learn two MACs on two different ports (simultaneously, to exercise
//      the learn-port arbiter)
//   2. look both up and check hit + correct one-hot port_mask
//   3. look up an unlearned MAC and check miss
//   4. run the ~4 Hz aging tick (with a small default_age for a fast test)
//      enough times to expire an entry, then confirm it now misses. Since
//      each tick only ages one quadrant of the bank, AGE_TICKS_PER_SWEEP
//      ticks are needed per full-bank sweep, regardless of which quadrant
//      a given entry's hash happens to land in.

`timescale 1ns/1ps

module tb_mac_addr_table;
  import mac_table_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  logic age_tick_i = 0;
  logic [AGE_W-1:0] default_age_i = 9'd3;
  logic [PORTMASK_W-1:0] flush_req_i = '0;
  wire                   flush_busy_o;

  logic [NUM_LEARN_PORTS-1:0]            learn_req_i;
  logic [NUM_LEARN_PORTS-1:0][MAC_W-1:0] learn_mac_i;
  logic [NUM_LEARN_PORTS-1:0]            learn_busy_o;

  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_req_i;
  logic [NUM_LOOKUP_PORTS-1:0][MAC_W-1:0]      lookup_mac_i;
  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_busy_o;
  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_result_valid_o;
  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_result_hit_o;
  logic [NUM_LOOKUP_PORTS-1:0][PORTMASK_W-1:0] lookup_result_port_mask_o;

  int errors = 0;

  mac_addr_table_top dut (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .age_tick_i                 (age_tick_i),
    .default_age_i              (default_age_i),
    .flush_req_i                (flush_req_i),
    .flush_busy_o               (flush_busy_o),
    .learn_req_i                (learn_req_i),
    .learn_mac_i                (learn_mac_i),
    .learn_busy_o               (learn_busy_o),
    .lookup_req_i               (lookup_req_i),
    .lookup_mac_i               (lookup_mac_i),
    .lookup_busy_o              (lookup_busy_o),
    .lookup_result_valid_o      (lookup_result_valid_o),
    .lookup_result_hit_o        (lookup_result_hit_o),
    .lookup_result_port_mask_o  (lookup_result_port_mask_o)
  );

  always #5 clk = ~clk;

  localparam logic [47:0] MAC_A = 48'h00_11_22_33_44_55;
  localparam logic [47:0] MAC_B = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [47:0] MAC_UNKNOWN = 48'h12_34_56_78_9A_BC;

  task automatic do_lookup(input int port, input logic [47:0] mac,
                            output logic hit, output logic [PORTMASK_W-1:0] mask);
    int timeout;
    bit timed_out;
    @(posedge clk);
    lookup_req_i[port] <= 1'b1;
    lookup_mac_i[port] <= mac;
    @(posedge clk);
    lookup_req_i[port] <= 1'b0;
    timeout   = 0;
    timed_out = 1'b0;
    while (!lookup_result_valid_o[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 2000) begin
        $display("FAIL: lookup on port %0d timed out waiting for result", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    if (timed_out) begin
      hit  = 1'bx;
      mask = '0;
    end else begin
      hit  = lookup_result_hit_o[port];
      mask = lookup_result_port_mask_o[port];
    end
  endtask

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // Issues one age_tick_i pulse and waits for that quadrant's sweep to
  // finish. Since each tick only ages one quadrant, AGE_TICKS_PER_SWEEP
  // calls to this task are needed to fully age every entry in the bank
  // once, regardless of which quadrant it lives in.
  task automatic do_tick_and_wait_quadrant_sweep;
    @(posedge clk);
    age_tick_i <= 1'b1;
    @(posedge clk);
    age_tick_i <= 1'b0;
    // Each entry now costs REQ(2, arbiter grant registration) + READ(1) +
    // WRITE(1) + GAP(1) = ~5 cycles when uncontended (more under learn
    // contention); use a generous margin well above that so this testbench
    // wait never races the real sweep -- irrelevant to real timing, since
    // even a heavily-contended sweep finishes in a tiny fraction of the
    // ~250ms tick period.
    wait_cycles(8*AGE_QUAD_DEPTH + 200);
  endtask

  logic hit;
  logic [PORTMASK_W-1:0] mask;

  task automatic print_ages_bank0;
    for (int a = 0; a < BANK_DEPTH; a++) begin
      if (dut.g_banks[0].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_A && dut.g_banks[0].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_A in bank 0 addr %0d age=%0d", a, dut.g_banks[0].u_bank.mem[a][AGE_W-1:0]);
      if (dut.g_banks[0].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_B && dut.g_banks[0].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_B in bank 0 addr %0d age=%0d", a, dut.g_banks[0].u_bank.mem[a][AGE_W-1:0]);
    end
  endtask
  task automatic print_ages_bank1;
    for (int a = 0; a < BANK_DEPTH; a++) begin
      if (dut.g_banks[1].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_A && dut.g_banks[1].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_A in bank 1 addr %0d age=%0d", a, dut.g_banks[1].u_bank.mem[a][AGE_W-1:0]);
      if (dut.g_banks[1].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_B && dut.g_banks[1].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_B in bank 1 addr %0d age=%0d", a, dut.g_banks[1].u_bank.mem[a][AGE_W-1:0]);
    end
  endtask
  task automatic print_ages_bank2;
    for (int a = 0; a < BANK_DEPTH; a++) begin
      if (dut.g_banks[2].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_A && dut.g_banks[2].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_A in bank 2 addr %0d age=%0d", a, dut.g_banks[2].u_bank.mem[a][AGE_W-1:0]);
      if (dut.g_banks[2].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_B && dut.g_banks[2].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_B in bank 2 addr %0d age=%0d", a, dut.g_banks[2].u_bank.mem[a][AGE_W-1:0]);
    end
  endtask
  task automatic print_ages_bank3;
    for (int a = 0; a < BANK_DEPTH; a++) begin
      if (dut.g_banks[3].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_A && dut.g_banks[3].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_A in bank 3 addr %0d age=%0d", a, dut.g_banks[3].u_bank.mem[a][AGE_W-1:0]);
      if (dut.g_banks[3].u_bank.mem[a][ENTRY_W-1 -: MAC_W] == MAC_B && dut.g_banks[3].u_bank.mem[a][AGE_W-1:0] != 0)
        $display("DEBUG: MAC_B in bank 3 addr %0d age=%0d", a, dut.g_banks[3].u_bank.mem[a][AGE_W-1:0]);
    end
  endtask
  task automatic print_ages(input string tag);
    $display("--- %s ---", tag);
    print_ages_bank0();
    print_ages_bank1();
    print_ages_bank2();
    print_ages_bank3();
  endtask

  initial begin
    learn_req_i  = '0;
    learn_mac_i  = '0;
    lookup_req_i = '0;
    lookup_mac_i = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // learn MAC_A on port 0 and MAC_B on port 3 in the same cycle to
    // exercise the learn-port round-robin arbiter
    @(posedge clk);
    learn_req_i[0] <= 1'b1; learn_mac_i[0] <= MAC_A;
    learn_req_i[3] <= 1'b1; learn_mac_i[3] <= MAC_B;
    @(posedge clk);
    learn_req_i[0] <= 1'b0;
    learn_req_i[3] <= 1'b0;

    wait_cycles(200);

    print_ages("after learn");

    // lookup MAC_A from port 2 -> expect hit, mask bit0 set (learned on port 0)
    do_lookup(2, MAC_A, hit, mask);
    if (hit !== 1'b1 || mask !== 8'b0000_0001) begin
      $display("FAIL: lookup(MAC_A) hit=%0b mask=%08b, expected hit=1 mask=00000001", hit, mask);
      errors++;
    end else begin
      $display("PASS: lookup(MAC_A) hit=%0b mask=%08b", hit, mask);
    end

    // lookup MAC_B from port 5 -> expect hit, mask bit3 set (learned on port 3)
    do_lookup(5, MAC_B, hit, mask);
    if (hit !== 1'b1 || mask !== 8'b0000_1000) begin
      $display("FAIL: lookup(MAC_B) hit=%0b mask=%08b, expected hit=1 mask=00001000", hit, mask);
      errors++;
    end else begin
      $display("PASS: lookup(MAC_B) hit=%0b mask=%08b", hit, mask);
    end

    // lookup an unknown MAC -> expect miss
    do_lookup(1, MAC_UNKNOWN, hit, mask);
    if (hit !== 1'b0) begin
      $display("FAIL: lookup(MAC_UNKNOWN) hit=%0b, expected miss", hit);
      errors++;
    end else begin
      $display("PASS: lookup(MAC_UNKNOWN) missed as expected");
    end

    // age out MAC_A/MAC_B: default_age_i = 3, so 3 full-bank sweeps should
    // bring age to 0. Each tick only sweeps one quadrant, so issue
    // AGE_TICKS_PER_SWEEP*3 ticks to guarantee 3 full sweeps regardless of
    // which quadrant MAC_A/MAC_B's hash buckets happen to fall into.
    for (int s = 0; s < AGE_TICKS_PER_SWEEP*3; s++) begin
      do_tick_and_wait_quadrant_sweep();
      print_ages($sformatf("tick %0d", s));
    end

    do_lookup(2, MAC_A, hit, mask);
    if (hit !== 1'b0) begin
      $display("FAIL: lookup(MAC_A) after aging out, hit=%0b, expected miss", hit);
      errors++;
    end else begin
      $display("PASS: MAC_A aged out as expected");
    end

    do_lookup(5, MAC_B, hit, mask);
    if (hit !== 1'b0) begin
      $display("FAIL: lookup(MAC_B) after aging out, hit=%0b, expected miss", hit);
      errors++;
    end else begin
      $display("PASS: MAC_B aged out as expected");
    end

    // ---- port flush (link-down): expires exactly that port's entries ----
    begin
      localparam logic [47:0] MAC_C = 48'h02_00_00_00_00_C3;
      localparam logic [47:0] MAC_D = 48'h02_00_00_00_00_D5;
      logic [PORTMASK_W-1:0] m2;
      @(posedge clk);
      learn_req_i[0] <= 1'b1; learn_mac_i[0] <= MAC_A;
      learn_req_i[3] <= 1'b1; learn_mac_i[3] <= MAC_B;
      @(posedge clk); learn_req_i[0] <= 1'b0; learn_req_i[3] <= 1'b0;
      wait_cycles(100);
      @(posedge clk); learn_req_i[3] <= 1'b1; learn_mac_i[3] <= MAC_C;
      @(posedge clk); learn_req_i[3] <= 1'b0;
      wait_cycles(100);
      @(posedge clk); learn_req_i[4] <= 1'b1; learn_mac_i[4] <= MAC_D;
      @(posedge clk); learn_req_i[4] <= 1'b0;
      wait_cycles(100);
      do_lookup(2, MAC_B, hit, mask); if (hit !== 1'b1) begin $display("FAIL: pre-flush MAC_B should hit"); errors++; end

      // flush port 3 while an aging quadrant sweep is running (must wait for it)
      @(posedge clk); age_tick_i <= 1'b1; @(posedge clk); age_tick_i <= 1'b0;
      wait_cycles(20);
      @(posedge clk); flush_req_i[3] <= 1'b1; @(posedge clk); flush_req_i[3] <= 1'b0;
      wait_cycles(2);
      if (flush_busy_o !== 1'b1) begin $display("FAIL: flush_busy_o not asserted after request"); errors++; end
      wait (flush_busy_o === 1'b0);
      wait_cycles(10);

      do_lookup(2, MAC_B, hit, mask); if (hit !== 1'b0) begin $display("FAIL: MAC_B (port 3) survived flush of port 3"); errors++; end
      else $display("PASS: MAC_B expired by flush of port 3");
      do_lookup(2, MAC_C, hit, mask); if (hit !== 1'b0) begin $display("FAIL: MAC_C (port 3) survived flush of port 3"); errors++; end
      else $display("PASS: MAC_C expired by flush of port 3");
      do_lookup(2, MAC_A, hit, mask); if (hit !== 1'b1 || mask !== 8'b0000_0001) begin $display("FAIL: MAC_A (port 0) damaged by flush of port 3"); errors++; end
      else $display("PASS: MAC_A (port 0) untouched by flush of port 3");
      do_lookup(2, MAC_D, hit, mask); if (hit !== 1'b1 || mask !== 8'b0001_0000) begin $display("FAIL: MAC_D (port 4) damaged by flush of port 3"); errors++; end
      else $display("PASS: MAC_D (port 4) untouched by flush of port 3");

      // two ports at once, requests in different cycles (merged/sequenced)
      @(posedge clk); flush_req_i[0] <= 1'b1; @(posedge clk); flush_req_i[0] <= 1'b0;
      @(posedge clk); flush_req_i[4] <= 1'b1; @(posedge clk); flush_req_i[4] <= 1'b0;
      wait_cycles(4); wait (flush_busy_o === 1'b0); wait_cycles(10);
      do_lookup(2, MAC_A, hit, mask); if (hit !== 1'b0) begin $display("FAIL: MAC_A survived flush of port 0"); errors++; end
      do_lookup(2, MAC_D, hit, mask); if (hit !== 1'b0) begin $display("FAIL: MAC_D survived flush of port 4"); errors++; end
      else $display("PASS: back-to-back flushes of ports 0 and 4 both took effect");

      // a learn after the flush works normally
      @(posedge clk); learn_req_i[3] <= 1'b1; learn_mac_i[3] <= MAC_B;
      @(posedge clk); learn_req_i[3] <= 1'b0; wait_cycles(100);
      do_lookup(2, MAC_B, hit, mask); if (hit !== 1'b1 || mask !== 8'b0000_1000) begin $display("FAIL: re-learn after flush"); errors++; end
      else $display("PASS: address re-learned after flush");
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);

    $finish;
  end

  // safety timeout
  initial begin
    #2_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
