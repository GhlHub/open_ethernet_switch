// sfp_sideband.sv
//
// SFP+ module sideband control (MOD_ABS, TX_FAULT, LOS in; TX_DISABLE out).
// Runs on the AXI-Lite clock. TX_DISABLE is high (laser off) unless the module
// is present, has been settled, has no unrecovered fault, and software has not
// forced it off:
//
//   ABSENT   MOD_ABS high (debounced): laser off.
//   SETTLE   module just inserted: laser stays off for SETTLE_MS (SFF-8472
//            module initialization is up to 300 ms).
//   RUN      TX_DISABLE = software force bit. TX_FAULT asserted (debounced)
//            -> FAULT_HOLD.
//   FAULT_HOLD  laser off for HOLD_MS (>= the 10 us TX_DISABLE pulse that
//            resets TX_FAULT in SFF-8431), then RESTART.
//   RESTART  laser on again, TX_FAULT ignored for RESTART_MS (module t_init),
//            then back to RUN. Each fault increments fault_count; after
//            MAX_RETRIES consecutive faults -> LOCKOUT.
//   LOCKOUT  laser stays off until software writes the clear-lockout bit or
//            the module is removed. fault_count resets after HEALTHY_MS in RUN
//            without a fault.
//
// LOS is only reported (status bit): it means "no receive light", not a laser
// hazard; the PCS synchronization and auto-negotiation already drop the link.
// All three inputs are asynchronous pins and pass through 2-flop synchronizers.
// Sticky status: fault_seen, removed_seen (cleared by clr_* pulses).

module sfp_sideband #(
  parameter int CLK_HZ      = 142_857_000,
  parameter int DEBOUNCE_MS = 10,
  parameter int SETTLE_MS   = 300,
  parameter int HOLD_MS     = 2,
  parameter int RESTART_MS  = 300,
  parameter int HEALTHY_MS  = 5000,
  parameter int MAX_RETRIES = 3
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        mod_abs_i,
  input  logic        tx_fault_i,
  input  logic        los_i,
  output logic        tx_disable_o,

  input  logic        force_disable_i,   // software: keep the laser off
  input  logic        clr_fault_seen_i,  // one-cycle pulses
  input  logic        clr_removed_seen_i,
  input  logic        clr_lockout_i,

  output logic [15:0] status_o
  // [0] mod_abs (debounced)  [1] los  [2] tx_fault (synced)  [3] tx_disable
  // [4] lockout  [5] fault_seen  [6] removed_seen  [7] 0
  // [15:8] consecutive fault count
);

  localparam int MS_DIV = CLK_HZ / 1000;

  // ---- input synchronizers ----
  (* ASYNC_REG = "TRUE" *) logic [1:0] abs_s, flt_s, los_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin abs_s <= 2'b11; flt_s <= '0; los_s <= '0; end
    else begin
      abs_s <= {abs_s[0], mod_abs_i};
      flt_s <= {flt_s[0], tx_fault_i};
      los_s <= {los_s[0], los_i};
    end
  end

  // ---- 1 ms tick ----
  logic [$clog2(MS_DIV)-1:0] div_q;
  logic tick_ms;
  assign tick_ms = (div_q == MS_DIV - 1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) div_q <= '0;
    else        div_q <= tick_ms ? '0 : div_q + 1'b1;
  end

  // ---- debounce MOD_ABS and TX_FAULT ----
  logic       absent_q, fault_q;
  logic [$clog2(DEBOUNCE_MS+1)-1:0] abs_cnt, flt_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      absent_q <= 1'b1; fault_q <= 1'b0; abs_cnt <= '0; flt_cnt <= '0;
    end else if (tick_ms) begin
      if (abs_s[1] == absent_q) abs_cnt <= '0;
      else if (abs_cnt == DEBOUNCE_MS - 1) begin absent_q <= abs_s[1]; abs_cnt <= '0; end
      else abs_cnt <= abs_cnt + 1'b1;

      if (flt_s[1] == fault_q) flt_cnt <= '0;
      else if (flt_cnt == 1) begin fault_q <= flt_s[1]; flt_cnt <= '0; end  // 2 ms
      else flt_cnt <= flt_cnt + 1'b1;
    end
  end

  // ---- control FSM ----
  typedef enum logic [2:0] {S_ABSENT, S_SETTLE, S_RUN, S_HOLD, S_RESTART, S_LOCKOUT} state_t;
  state_t state_q;
  logic [31:0] timer_q;
  logic [7:0]  fault_cnt_q;
  logic        fault_seen_q, removed_seen_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_ABSENT; timer_q <= '0; fault_cnt_q <= '0;
      fault_seen_q <= 1'b0; removed_seen_q <= 1'b0;
    end else begin
      if (clr_fault_seen_i)   fault_seen_q   <= 1'b0;
      if (clr_removed_seen_i) removed_seen_q <= 1'b0;

      if (absent_q && state_q != S_ABSENT) begin
        state_q <= S_ABSENT; fault_cnt_q <= '0; removed_seen_q <= 1'b1;
      end else begin
        case (state_q)
          S_ABSENT: if (!absent_q) begin state_q <= S_SETTLE; timer_q <= SETTLE_MS; end
          S_SETTLE: if (tick_ms) begin
            if (timer_q == 0) state_q <= S_RUN; else timer_q <= timer_q - 1'b1;
          end
          S_RUN: begin
            if (fault_q) begin
              fault_seen_q <= 1'b1;
              fault_cnt_q  <= fault_cnt_q + 1'b1;
              if (fault_cnt_q + 1'b1 >= 8'(MAX_RETRIES)) state_q <= S_LOCKOUT;
              else begin state_q <= S_HOLD; timer_q <= HOLD_MS; end
            end else if (tick_ms) begin
              if (timer_q >= HEALTHY_MS) fault_cnt_q <= '0; else timer_q <= timer_q + 1'b1;
            end
          end
          S_HOLD: if (tick_ms) begin
            if (timer_q == 0) begin state_q <= S_RESTART; timer_q <= RESTART_MS; end
            else timer_q <= timer_q - 1'b1;
          end
          S_RESTART: if (tick_ms) begin
            if (timer_q == 0) begin state_q <= S_RUN; timer_q <= '0; end
            else timer_q <= timer_q - 1'b1;
          end
          S_LOCKOUT: if (clr_lockout_i) begin
            fault_cnt_q <= '0; state_q <= S_SETTLE; timer_q <= SETTLE_MS;
          end
          default: state_q <= S_ABSENT;
        endcase
      end
    end
  end

  // RUN entry from SETTLE/RESTART must restart the healthy timer
  // (timer_q is reloaded to 0 on RESTART->RUN; SETTLE ends at 0)

  logic tx_dis_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) tx_dis_q <= 1'b1;
    else        tx_dis_q <= !((state_q == S_RUN || state_q == S_RESTART) && !force_disable_i);
  end
  assign tx_disable_o = tx_dis_q;

  assign status_o = {fault_cnt_q, 1'b0, removed_seen_q, fault_seen_q, (state_q == S_LOCKOUT),
                     tx_dis_q, flt_s[1], los_s[1], absent_q};
endmodule
