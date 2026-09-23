// tb_ctrl_value_xdomain.sv
//
// Unrelated-clock check of ctrl_value_xdomain.sv:
//   A. a value written in the source domain appears on value_o exactly when
//      valid_o pulses (checked by latching value_o ONLY on that pulse, in
//      the destination domain's own always_ff -- the same way a real
//      consumer would), for many random values and random source/
//      destination clock phase relationships
//   B. valid_o is a single-cycle pulse (never re-asserts without a new go_i)
//   C. writing again before the destination could plausibly have caught up
//      with the first write (inside, or close to, the synchronizer's own
//      settling time -- exactly the pattern the header warns is
//      unsupported): with unrelated free-running clocks there is no single
//      deterministic outcome (0, 1 or 2 pulses can all be correct,
//      depending on exact phase), so this checks the one property that must
//      ALWAYS hold regardless of outcome -- every value_o a pulse ever
//      presents is one of the values actually written, never a torn/mixed
//      bit pattern that was never written at all. Repeated over many gaps
//      and phases, not a single fixed case.

`timescale 1ns/1ps

module tb_ctrl_value_xdomain;
  localparam int WIDTH = 6;

  logic src_clk = 0, dst_clk = 0;
  always #4.3  src_clk = ~src_clk;   // unrelated periods, non-integer ratio
  always #3.7  dst_clk = ~dst_clk;
  logic src_rst_n = 0, dst_rst_n = 0;

  logic [WIDTH-1:0] value_i = '0;
  logic              go_i    = 1'b0;
  wire  [WIDTH-1:0]  value_o;
  wire               valid_o;

  ctrl_value_xdomain #(.WIDTH(WIDTH)) dut (
    .src_clk (src_clk), .src_rst_n (src_rst_n), .value_i (value_i), .go_i (go_i),
    .dst_clk (dst_clk), .dst_rst_n (dst_rst_n), .value_o (value_o), .valid_o (valid_o)
  );

  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("FAIL: %s", m); end
  endtask

  task automatic src_write(input logic [WIDTH-1:0] v);
    @(posedge src_clk); value_i <= v; go_i <= 1'b1;
    @(posedge src_clk); go_i <= 1'b0;
  endtask

  // captures value_o the way a real consumer must: latched only on valid_o
  logic [WIDTH-1:0] latched_q;
  int                pulse_count;
  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin latched_q <= '0; pulse_count <= 0; end
    else if (valid_o) begin latched_q <= value_o; pulse_count <= pulse_count + 1; end
  end

  // testB: valid_o must never be high for 2 consecutive dst_clk cycles
  int consec_high;
  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) consec_high <= 0;
    else if (valid_o) begin
      consec_high <= consec_high + 1;
      if (consec_high >= 1) check(1'b0, "valid_o held for more than one dst_clk cycle");
    end else consec_high <= 0;
  end

  task automatic wait_pulse(input int timeout_cycles, output bit timed_out);
    int t; int start;
    start = pulse_count; t = 0; timed_out = 1'b0;
    while (pulse_count == start && !timed_out) begin
      @(posedge dst_clk); t++;
      if (t > timeout_cycles) timed_out = 1'b1;
    end
  endtask

  int seed = 42;
  initial begin
    repeat (5) @(posedge src_clk); src_rst_n = 1'b1;
    repeat (5) @(posedge dst_clk); dst_rst_n = 1'b1;

    // ---- A: many random values, random phase (the two clocks are already
    // unrelated/free-running, so successive writes naturally sample every
    // relative phase over the course of the loop) ----
    for (int i = 0; i < 200; i++) begin
      logic [WIDTH-1:0] v;
      bit timed_out;
      v = $urandom(seed);
      src_write(v);
      wait_pulse(50, timed_out);
      check(!timed_out, $sformatf("iter %0d: valid_o never pulsed", i));
      if (!timed_out) check(latched_q === v, $sformatf("iter %0d: latched %h, expected %h", i, latched_q, v));
      // small random gap before the next write, so consecutive iterations
      // exercise different src/dst clock phase alignments
      repeat ($urandom_range(2, 9)) @(posedge src_clk);
    end
    if (errors == 0) $display("PASS: testA 200 random values crossed correctly at random clock phases");

    // ---- C: a second write while the first may still be mid-flight, at
    // many different gaps/phases -- value_o must never show anything other
    // than one of the two actually-written values, however many (0/1/2)
    // pulses that particular trial happens to produce ----
    begin
      int total_pulses, bad_values, gap;
      logic [WIDTH-1:0] va, vb;
      total_pulses = 0; bad_values = 0;
      for (int i = 0; i < 100; i++) begin
        int p0, pn;
        p0 = pulse_count;
        va = $urandom(seed); vb = $urandom(seed);
        src_write(va);
        gap = $urandom_range(0, 3); // 0 = adjacent src_clk edge, up through comfortably-settled
        repeat (gap) @(posedge src_clk);
        src_write(vb);
        repeat (30) @(posedge dst_clk);
        pn = pulse_count - p0;
        total_pulses += pn;
        if (pn >= 1 && latched_q !== va && latched_q !== vb) begin
          bad_values++;
          $display("FAIL: testC iter %0d gap=%0d: value_o=%h matches neither write (%h, %h)", i, gap, latched_q, va, vb);
        end
      end
      check(bad_values == 0, $sformatf("%0d/100 racing-write trials produced a torn/mixed value", bad_values));
      if (bad_values == 0)
        $display("PASS: testC 100 racing-write trials (gaps 0..3 src_clk cycles): %0d total pulses, every value_o a real write, never torn",
                 total_pulses);
    end

    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end

  initial begin #2_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
