// tb_async_fifo.sv
//
// Self-checking test for async_fifo.sv, standalone before it's relied on
// by the PS GEM bridge's CDC. Write clock and read clock are genuinely
// different, non-integer-ratio frequencies (125 MHz / 62.5 MHz -- the
// actual GEM-side/fabric-side rates this module exists for), unlike
// same-clock testing which wouldn't exercise the synchronizers at all.
//
//   A. push a known sequence with random write-side gaps, drain it with
//      random read-side gaps -> content and order preserved exactly
//   B. fill the FIFO until full_o asserts, confirm a write attempted
//      while full is correctly ignored (no corruption/overwrite), then
//      drain and confirm the dropped value never appears
//   C. sustained back-to-back traffic in both directions concurrently
//      (no artificial gaps) -> still exactly preserved, exercising the
//      synchronizers under maximum crossing rate

`timescale 1ns/1ps

module tb_async_fifo;

  localparam int WIDTH = 8;
  localparam int DEPTH = 64;

  logic wr_clk = 0;
  logic rd_clk = 0;
  logic wr_rst_n = 0;
  logic rd_rst_n = 0;

  always #4  wr_clk = ~wr_clk; // 125 MHz-equivalent
  always #8  rd_clk = ~rd_clk; // 62.5 MHz-equivalent

  logic [WIDTH-1:0] wr_data;
  logic             wr_en;
  logic             full;
  logic [WIDTH-1:0] rd_data;
  logic             rd_en;
  logic             empty;

  async_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .wr_clk   (wr_clk),
    .wr_rst_n (wr_rst_n),
    .wr_en_i  (wr_en),
    .wr_data_i(wr_data),
    .full_o   (full),
    .rd_clk   (rd_clk),
    .rd_rst_n (rd_rst_n),
    .rd_en_i  (rd_en),
    .rd_data_o(rd_data),
    .empty_o  (empty)
  );

  int errors = 0;

  // ---- capture on the read side ----
  byte cap[$];
  always_ff @(posedge rd_clk) begin
    if (rd_en && !empty) cap.push_back(byte'(rd_data));
  end

  // ---- capture what was actually WRITTEN (accepted), for comparison ----
  byte wcap[$];
  always_ff @(posedge wr_clk) begin
    if (wr_en && !full) wcap.push_back(byte'(wr_data));
  end

  // continuous writer: pushes 0,1,2,...,255,0,1,... with a mode-selected
  // gap pattern (0=no gaps/back-to-back, 1=~50% random gaps).
  //
  // wr_data is a direct combinational alias of wr_val_q -- deliberately
  // NOT a separate "next value" register mirrored into wr_data a cycle
  // later. An earlier version used two registers (wr_data <= wr_next_val
  // unconditionally, wr_next_val advancing only if the transfer was
  // accepted): that introduces a silent one-cycle lag between "the value
  // currently being offered" and "the value the advance decision looks
  // at", so a rejected transfer's retry ended up offering the *next*
  // value instead of retrying the rejected one -- corrupting the stream
  // (dropped/duplicated values) under exactly the back-to-back full
  // conditions this test exists to exercise. Aliasing wr_data straight to
  // wr_val_q removes the lag: what's offered and what's tracked are the
  // same register.
  int wr_mode = 0;
  logic [WIDTH-1:0] wr_val_q;
  assign wr_data = wr_val_q;

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_en    <= 1'b0;
      wr_val_q <= '0;
    end else begin
      // advance only once this cycle's offered value was actually accepted
      if (wr_en && !full) wr_val_q <= wr_val_q + 1'b1;

      if (wr_mode == 2)      wr_en <= 1'b0; // paused (used to hold traffic off between tests)
      else if (wr_mode == 1) wr_en <= ($urandom_range(0, 1) != 0);
      else                   wr_en <= 1'b1;
    end
  end

  int rd_mode = 0;
  initial begin
    rd_en = 1'b0;
    forever begin
      @(posedge rd_clk);
      if (!rd_rst_n) begin
        rd_en <= 1'b0;
      end else if (rd_mode == 2) begin
        rd_en <= 1'b0;
      end else if (rd_mode == 1 && $urandom_range(0, 1) == 0) begin
        rd_en <= 1'b0;
      end else begin
        rd_en <= 1'b1;
      end
    end
  end

  task automatic wait_wr_cycles(input int n); repeat (n) @(posedge wr_clk); endtask
  task automatic wait_rd_cycles(input int n); repeat (n) @(posedge rd_clk); endtask

  // re-pulse both resets between test phases: wr_val_q is exclusively
  // driven by its own always_ff now (see the note above it), so this is
  // the clean way to get each phase a fresh, known (0-based) sequence,
  // and it conveniently clears the DUT's own internal pointers too.
  task automatic reset_both();
    wr_rst_n = 1'b0;
    rd_rst_n = 1'b0;
    repeat (5) @(posedge wr_clk);
    wr_rst_n = 1'b1;
    repeat (5) @(posedge rd_clk);
    rd_rst_n = 1'b1;
  endtask

  initial begin
    repeat (5) @(posedge wr_clk);
    wr_rst_n = 1'b1;
    repeat (5) @(posedge rd_clk);
    rd_rst_n = 1'b1;

    // ---- test A: gapped traffic both sides ----
    wr_mode = 1;
    rd_mode = 1;
    wait_wr_cycles(600);
    wait_rd_cycles(20);
    wr_mode = 2; // pause writer
    wait_rd_cycles(40); // drain whatever's left
    rd_mode = 2; // pause reader

    if (cap.size() < 100) begin
      $display("FAIL: testA captured only %0d values, expected a substantial burst", cap.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      byte expect_val = 8'h00;
      for (int i = 0; i < cap.size(); i++) begin
        if (cap[i] !== expect_val) begin
          $display("FAIL: testA value %0d = %0d, expected %0d", i, cap[i], expect_val);
          ok = 1'b0;
          errors++;
        end
        expect_val = expect_val + 8'h01;
      end
      if (ok) $display("PASS: testA %0d values crossed the CDC in order, no loss/corruption", cap.size());
    end

    // ---- test B: fill to full, confirm a write while full is dropped ----
    cap.delete();
    reset_both();
    rd_mode = 2; // don't drain at all while filling
    wr_mode = 0; // back-to-back writes
    wait_wr_cycles(2 * DEPTH); // far more than enough to hit full_o
    if (!full) begin
      $display("FAIL: testB full_o never asserted after flooding the write side");
      errors++;
    end else begin
      $display("PASS: testB full_o asserted once the FIFO filled");
    end
    wr_mode = 2; // stop writing

    rd_mode = 0; // drain everything, back-to-back
    wait_rd_cycles(2 * DEPTH);
    rd_mode = 2;

    if (cap.size() != DEPTH) begin
      $display("FAIL: testB drained %0d values, expected exactly DEPTH=%0d (writes past full must be dropped, not overwrite)", cap.size(), DEPTH);
      errors++;
    end else begin
      bit ok = 1'b1;
      byte expect_val = 8'h00;
      for (int i = 0; i < cap.size(); i++) begin
        if (cap[i] !== expect_val) ok = 1'b0;
        expect_val = expect_val + 8'h01;
      end
      if (ok) $display("PASS: testB exactly DEPTH values survived, in order, overflow writes correctly dropped");
      else begin
        $display("FAIL: testB drained content mismatch");
        errors++;
      end
    end
    if (!empty) begin
      $display("FAIL: testB empty_o not asserted after fully draining");
      errors++;
    end

    // ---- test C: sustained back-to-back both directions ----
    cap.delete();
    reset_both();
    wr_mode = 0;
    rd_mode = 0;
    wait_wr_cycles(1000);
    wait_rd_cycles(30);
    wr_mode = 2;
    wait_rd_cycles(60);
    rd_mode = 2;

    if (cap.size() < 200) begin
      $display("FAIL: testC captured only %0d values, expected a large sustained burst", cap.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      byte expect_val = 8'h00;
      for (int i = 0; i < cap.size(); i++) begin
        if (cap[i] !== expect_val) ok = 1'b0;
        expect_val = expect_val + 8'h01;
      end
      if (ok) $display("PASS: testC %0d values at sustained back-to-back rate, in order, no loss/corruption", cap.size());
      else begin
        $display("FAIL: testC content mismatch under sustained traffic");
        errors++;
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
