// sync_1000base_x.sv
//
// IEEE 802.3 Clause 36.2.5.2 "Synchronization process" state machine.
// Decides whether the receive code-group stream is trustworthy enough to
// hand to the RX codec as real 1000BASE-X traffic (sync_ok_o) -- distinct
// from, and downstream of, GTH's own hardware comma/byte alignment
// (RXCOMMADETEN etc., configured in the GTH wrapper stage): that gets the
// *bit/byte* boundaries right, this validates that what's landing on
// those boundaries actually looks like a real 1000BASE-X code-group
// stream over a sustained window, per spec.
//
// NOTE: implemented from a secondary-source (tutorial-level) description
// of Clause 36.2.5.2's behavior, not the primitive IEEE 802.3 text/state
// diagram (Figure 36-9) directly -- the functional rules below (comma-
// then-odd-valid-run×3 to acquire; a leaky error counter to declare loss)
// are believed correct in substance, but the exact per-state names/edge
// cases in the formal spec weren't independently re-derived. Worth a
// direct cross-check against 802.3 Figure 36-9 before hardware bring-up
// if link stability ever looks marginal.
//
// Acquire phase: needs 3 consecutive ordered sets that each start with a
// (validly-decoded) comma and are followed by an odd number of
// consecutively-valid code groups before the next comma. Any invalid
// code group, or an even gap, resets the streak to 0.
//
// Once acquired, a leaky error counter (0..4) increments on each invalid
// code group or a comma arriving at the wrong phase (tracked via a free-
// running even/odd phase bit anchored at acquisition and re-anchored on
// every correctly-phased comma), decrements after every 4 consecutive
// good cycles (floored at 0), and drops sync (back to the acquire phase)
// on reaching 4.

module sync_1000base_x
  import sfp_pcs_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic [7:0] rxdata_i,
  input  logic       rxcharisk_i,
  input  logic       rxdisperr_i,
  input  logic       rxnotintable_i,

  output logic        sync_ok_o
);

  wire code_group_ok = !rxdisperr_i && !rxnotintable_i;
  wire is_comma       = rxcharisk_i && code_group_ok && (rxdata_i == K28_5);

  typedef enum logic { PH_ACQUIRE, PH_MONITOR } phase_t;
  phase_t phase_q;

  logic [13:0] gap_cnt_q;
  logic        gap_bad_q;
  logic [1:0]  acquire_streak_q;

  logic        rx_even_q;   // free-running code-group phase, monitor-phase only
  logic [2:0]  err_cnt_q;   // 0..4
  logic [1:0]  good_run_q;  // 0..3, counts toward the every-4th decrement

  logic sync_ok_q;
  assign sync_ok_o = sync_ok_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase_q          <= PH_ACQUIRE;
      gap_cnt_q        <= '0;
      gap_bad_q        <= 1'b0;
      acquire_streak_q <= '0;
      rx_even_q        <= 1'b0;
      err_cnt_q        <= '0;
      good_run_q       <= '0;
      sync_ok_q        <= 1'b0;
    end else if (phase_q == PH_ACQUIRE) begin
      if (is_comma) begin
        if (gap_cnt_q[0] && !gap_bad_q) begin // odd gap, all valid
          if (acquire_streak_q == 2'd2) begin
            phase_q          <= PH_MONITOR;
            sync_ok_q        <= 1'b1;
            // The cycle immediately after this comma is the "odd" (data)
            // position, so rx_even_q must anchor to 1 here, not 0 -- it's
            // read combinationally by the *next* cycle's comma check,
            // and that next cycle is a data position, not a comma one.
            rx_even_q        <= 1'b1;
            err_cnt_q        <= '0;
            good_run_q       <= '0;
            acquire_streak_q <= '0;
          end else begin
            acquire_streak_q <= acquire_streak_q + 1'b1;
          end
        end else begin
          acquire_streak_q <= '0;
        end
        gap_cnt_q <= '0;
        gap_bad_q <= 1'b0;
      end else begin
        gap_cnt_q <= gap_cnt_q + 1'b1;
        if (!code_group_ok) gap_bad_q <= 1'b1;
      end
    end else begin // PH_MONITOR
      rx_even_q <= ~rx_even_q;
      // Re-anchor on EVERY comma, not only ones judged correctly-phased:
      // a data frame's total code-group count is arbitrary, so roughly
      // half of all real frames leave the free-running toggle one step
      // out of phase with the next idle comma purely from frame length
      // parity -- not a real fault. Re-anchoring only on "good" commas
      // meant a single such parity mismatch, once introduced, could
      // never self-correct (every later comma would keep landing on the
      // same now-wrong phase forever, since both the toggle and idle's
      // own comma/data alternation advance at the same rate). This still
      // counts a mis-phased comma toward the leaky error budget below --
      // it just stops that single event from becoming a permanent lock-
      // out, which sustained real corruption (the actual thing this
      // counter exists to catch) doesn't need to rely on anyway.
      if (is_comma) rx_even_q <= 1'b1;
      if (!code_group_ok || (is_comma && rx_even_q)) begin
        if (err_cnt_q == 3'd3) begin
          phase_q          <= PH_ACQUIRE;
          sync_ok_q        <= 1'b0;
          acquire_streak_q <= '0;
          gap_cnt_q        <= '0;
          gap_bad_q        <= 1'b0;
        end else begin
          err_cnt_q <= err_cnt_q + 1'b1;
        end
        good_run_q <= '0;
      end else begin
        if (good_run_q == 2'd3) begin
          good_run_q <= '0;
          if (err_cnt_q != '0) err_cnt_q <= err_cnt_q - 1'b1;
        end else begin
          good_run_q <= good_run_q + 1'b1;
        end
      end
    end
  end

endmodule
