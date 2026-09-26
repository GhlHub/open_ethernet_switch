// bank_arbiter.sv
//
// Grants exclusive use of one bank's shared port A to learning, that bank's
// aging_sweep_fsm, or the lowest-priority dump reader. Dump reads yield
// immediately to either existing client; their read-modify-write transactions
// retain their grants until complete. One instance per bank (learn's
// request is broadcast identically to all NUM_BANKS instances since learn
// needs a synchronized view of the same row across all 4 banks; aging is
// independent per bank so each instance sees only its own bank's aging
// request).
//
// Learn has fixed priority: it is granted the bus as soon as it asks,
// never queued behind aging. This is intentional and safe because aging
// yields the bus every single entry (aging_sweep_fsm drops its request for
// one cycle between each row -- see the S_GAP state there), so a pending
// learn request is never blocked for more than the ~2 cycles it takes to
// finish whichever single aging row-transaction is already in flight, and
// aging still makes steady progress through the gaps. Aging has enormous
// timing slack (one quadrant sweep needs to finish well within a ~250ms
// tick period), so unconditional learn priority costs it nothing in
// practice; only a learn engine that requested the bus on literally every
// single cycle, forever, could fully starve aging, which is not a
// realistic traffic pattern for a learn path driven by packet arrivals.

module bank_arbiter (
  input  logic clk,
  input  logic rst_n,

  input  logic learn_req_i,
  input  logic aging_req_i,
  input logic dump_req_i,
  output wire dump_gnt_o,

  output logic learn_gnt_o,
  output logic aging_gnt_o
);

  typedef enum logic [1:0] {S_IDLE, S_LEARN, S_AGING, S_DUMP} state_t;
  state_t state_q, state_d;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      S_IDLE: begin
        if (learn_req_i)      state_d = S_LEARN; // learn: fixed priority
        else if (aging_req_i) state_d = S_AGING;
        else if (dump_req_i) state_d = S_DUMP;
      end
      S_LEARN: if (!learn_req_i) state_d = S_IDLE;
      S_AGING: if (!aging_req_i) state_d = S_IDLE;
      S_DUMP: begin
        if (learn_req_i) state_d=S_LEARN;
        else if (aging_req_i) state_d=S_AGING;
        else if (!dump_req_i) state_d=S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_q <= S_IDLE;
    else        state_q <= state_d;
  end

  assign dump_gnt_o = (state_q==S_DUMP) && !learn_req_i && !aging_req_i;
  assign learn_gnt_o = (state_q == S_LEARN);
  assign aging_gnt_o = (state_q == S_AGING);

endmodule
