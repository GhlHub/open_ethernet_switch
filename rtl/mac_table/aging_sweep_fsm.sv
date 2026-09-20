// aging_sweep_fsm.sv
//
// One instance per bank. On tick_i (expected to already be a single-cycle
// pulse in this clock domain -- see the synchronizer in
// mac_addr_table_top), walks one quadrant (1/AGE_TICKS_PER_SWEEP) of the
// bank's BANK_DEPTH entries via port A and decrements age by 1 if non-zero.
// Successive ticks advance to the next quadrant, round-robin, so the whole
// bank is aged once every AGE_TICKS_PER_SWEEP ticks (~1 second at the
// expected ~4 Hz tick rate: 4 ticks x 128 entries = 512 entries/bank).
//
// Port A is shared with the learn engine (bank_arbiter, one instance per
// bank, gives learn fixed priority). This FSM re-arbitrates for the bus on
// every single entry rather than holding it for the whole quadrant sweep:
// after each entry's read+write it drops bus_req_o for one cycle (S_GAP)
// before requesting the next entry, so a pending learn request is never
// blocked for more than the ~2 cycles it takes to finish whichever single
// entry is already in flight. This costs aging a couple of extra cycles
// per entry versus a dedicated port, which is irrelevant given its huge
// timing slack against the ~250ms tick period.
//
// BANK_DEPTH and AGE_TICKS_PER_SWEEP are both powers of two, so the
// quadrant select is just the upper AGE_QUAD_SEL_W bits of the row address
// and the in-quadrant offset the lower AGE_QUAD_ADDR_W bits -- no
// multiply/divide needed, and "last entry of this quadrant" is simply the
// low address bits all being 1.
//
// A tick arriving while a quadrant sweep is still in progress is ignored
// (should not happen given the above, but avoids re-entrancy if it ever
// did).
//
// Port flush (link-down): a one-cycle flush_start_i while idle (it takes
// priority over a same-cycle tick) walks the WHOLE bank instead, using the
// same per-entry bus handshake. Every non-empty entry whose port mask has
// any bit in flush_mask_i loses those bits; if none remain the age is set to 0,
// i.e. the entry is expired (age 0 = empty slot). busy_o is high from
// the start request until a sweep finishes. A tick that arrives during a
// flush is ignored, so aging lags by at most that one tick.

module aging_sweep_fsm
  import mac_table_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic tick_i,

  input  logic                    flush_start_i,
  input  logic [PORTMASK_W-1:0]   flush_mask_i,
  output logic                    busy_o,   // any sweep (aging quadrant or flush) in progress

  // shared bank-A bus arbitration (see bank_arbiter; learn has priority)
  output logic bus_req_o,
  input  logic bus_gnt_i,

  output logic                   a_en_o,
  output logic                   a_we_o,
  output logic [BANK_ADDR_W-1:0] a_addr_o,
  output logic [ENTRY_W-1:0]     a_wdata_o,
  input  logic [ENTRY_W-1:0]     a_rdata_i
);

  typedef enum logic [2:0] {S_IDLE, S_REQ, S_READ, S_WRITE, S_GAP} state_t;
  state_t state_q, state_d;

  logic [BANK_ADDR_W-1:0]     addr_q;
  logic [AGE_QUAD_SEL_W-1:0]  quadrant_q;
  logic                       flush_mode_q;
  logic [PORTMASK_W-1:0]      flush_mask_q;

  // true when addr_q is the last row of the quadrant currently being swept
  wire quad_last_q = (addr_q[AGE_QUAD_ADDR_W-1:0] == {AGE_QUAD_ADDR_W{1'b1}});
  wire bank_last   = (addr_q == {BANK_ADDR_W{1'b1}});
  wire quad_last   = flush_mode_q ? bank_last : quad_last_q;

  // Entry field access is inlined (rather than calling the mac_table_pkg
  // entry_age/entry_mac/entry_port_mask/make_entry functions) because this
  // module is instantiated NUM_BANKS times: Icarus Verilog 12.0 has a
  // confirmed bug where the same package-scope `function automatic`,
  // called every cycle from more than one module instance in lockstep,
  // corrupts simulation (verified with a minimal reproduction -- it only
  // appears with >=2 instances and a real non-zero write; inlining the
  // exact same bit-slicing makes it disappear). Plain part-selects have no
  // such issue and are exactly as synthesizable.
  wire [AGE_W-1:0]      rd_age  = a_rdata_i[AGE_W-1:0];
  wire [PORTMASK_W-1:0] rd_pmask = a_rdata_i[AGE_W +: PORTMASK_W];
  wire                  flush_hit = (rd_age != '0) && ((rd_pmask & flush_mask_q) != '0);
  wire [PORTMASK_W-1:0] flush_new_mask = rd_pmask & ~flush_mask_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_IDLE;
      addr_q     <= '0;
      quadrant_q <= '0;
      flush_mode_q <= 1'b0;
      flush_mask_q <= '0;
    end else begin
      state_q <= state_d;
      if (state_q == S_IDLE && flush_start_i) begin
        flush_mode_q <= 1'b1;
        flush_mask_q <= flush_mask_i;
        addr_q       <= '0;
      end else if (state_q == S_IDLE && tick_i) begin
        // start of a new quadrant sweep: quadrant_q in the high bits,
        // in-quadrant offset reset to 0
        flush_mode_q <= 1'b0;
        addr_q <= {quadrant_q, {AGE_QUAD_ADDR_W{1'b0}}};
      end else if (state_q == S_WRITE) begin
        addr_q <= addr_q + 1'b1;
        if (quad_last && !flush_mode_q) quadrant_q <= quadrant_q + 1'b1; // wraps mod AGE_TICKS_PER_SWEEP
      end
    end
  end

  always_comb begin
    state_d   = state_q;
    bus_req_o = (state_q == S_REQ || state_q == S_READ || state_q == S_WRITE);
    a_en_o    = 1'b0;
    a_we_o    = 1'b0;
    a_addr_o  = addr_q;
    if (flush_mode_q)
      a_wdata_o = {a_rdata_i[ENTRY_W-1:AGE_W+PORTMASK_W], flush_new_mask,
                   (flush_new_mask == '0) ? {AGE_W{1'b0}} : rd_age};
    else
      a_wdata_o = {a_rdata_i[ENTRY_W-1:AGE_W], rd_age - 1'b1};
    busy_o = (state_q != S_IDLE);

    unique case (state_q)
      S_IDLE: begin
        if (flush_start_i || tick_i) state_d = S_REQ;
      end
      S_REQ: begin
        if (bus_gnt_i) state_d = S_READ;
      end
      S_READ: begin
        a_en_o  = 1'b1;
        a_we_o  = 1'b0;
        state_d = S_WRITE;
      end
      S_WRITE: begin
        if (flush_mode_q ? flush_hit : (rd_age != '0)) begin
          a_en_o = 1'b1;
          a_we_o = 1'b1;
        end
        if (quad_last) state_d = S_IDLE;
        else           state_d = S_GAP;
      end
      S_GAP: begin
        // bus_req_o is low this one cycle (see the assignment above),
        // giving bank_arbiter a clean chance to hand the bus to learn
        // before this FSM asks again for the next entry
        state_d = S_REQ;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
