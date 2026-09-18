// learn_engine_fsm.sv
//
// Drains the learn request FIFO one entry at a time. For each request:
//   1. arbitrate for the shared bank-A bus against aging (bus_req_o/
//      bus_gnt_i; see bank_arbiter -- learn has fixed priority, one
//      arbiter instance per bank, this engine only proceeds once all
//      NUM_BANKS instances have granted it, since it needs a synchronized
//      view of the same row across all 4 banks)
//   2. pop the FIFO entry and issue a read to all 4 banks at the hash index
//   3. once read data lands, decide which way to write:
//        - MAC already present in one of the 4 ways -> refresh that way
//        - else an empty way (age==0) exists         -> use that way
//        - else                                       -> evict the way with
//                                                          the smallest age
//   4. write the (mac, port_mask, default_age) entry into the chosen way
//
// port_mask is written as a one-hot mask with just the learning port's bit
// set, refreshed on every re-learn (so it always reflects the most recent
// source port for that MAC).
//
// This engine drives bank port A (shared with aging); lookup has its own
// dedicated port B and is not involved here at all.

module learn_engine_fsm
  import mac_table_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic [AGE_W-1:0]        default_age_i,

  // learn FIFO pop side
  input  logic                        fifo_empty_i,
  input  logic [LEARN_FIFO_W-1:0]     fifo_rd_data_i,
  output logic                        fifo_rd_en_o,

  // shared bank-A bus arbitration (bus_gnt_i = AND of all NUM_BANKS
  // per-bank bank_arbiter grants, computed at the top level)
  output logic bus_req_o,
  input  logic bus_gnt_i,

  // bank port A (read all ways, write the chosen way)
  output logic [NUM_BANKS-1:0]   a_en_o,
  output logic [NUM_BANKS-1:0]   a_we_o,
  output logic [BANK_ADDR_W-1:0] a_addr_o,
  output logic [ENTRY_W-1:0]     a_wdata_o,
  input  logic [ENTRY_W-1:0]     a_rdata_i [NUM_BANKS]
);

  typedef enum logic [2:0] {S_IDLE, S_REQ, S_POP, S_READ_LAT, S_WRITE} state_t;
  state_t state_q, state_d;

  logic [MAC_W-1:0]       mac_q;
  logic [LEARN_ID_W-1:0]  port_id_q;
  logic [BANK_ADDR_W-1:0] hash_q;

  wire [MAC_W-1:0]       fifo_mac  = fifo_rd_data_i[LEARN_FIFO_W-1 -: MAC_W];
  wire [LEARN_ID_W-1:0]  fifo_pid  = fifo_rd_data_i[BANK_ADDR_W +: LEARN_ID_W];
  wire [BANK_ADDR_W-1:0] fifo_hash = fifo_rd_data_i[BANK_ADDR_W-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_q <= S_IDLE;
    else        state_q <= state_d;
  end

  always_ff @(posedge clk) begin
    if (state_q == S_POP) begin
      mac_q     <= fifo_mac;
      port_id_q <= fifo_pid;
      hash_q    <= fifo_hash;
    end
  end

  // ---- 4-way decision, valid once a_rdata_i reflects hash_q (S_READ_LAT/S_WRITE) ----
  //
  // NUM_BANKS is architecturally fixed at 4 (the spec's "4 x 512-entry
  // RAMs"), so the 4 ways are handled with explicitly named signals below
  // rather than a procedural for-loop over an indexed vector/array.
  // Icarus Verilog 12.0 miscompiles a for-loop that writes different bit
  // positions of the same vector across iterations (confirmed: it silently
  // corrupts the result), so per-way state is never accumulated into a
  // vector that way -- every assignment below is either a whole-vector
  // assignment or a plain named boolean.
  // Field access is inlined (rather than calling the mac_table_pkg
  // entry_empty/entry_mac/entry_age/make_entry functions): see the note in
  // aging_sweep_fsm.sv for why RTL avoids calling those package functions.
  // This module is single-instance today, but is kept consistent with the
  // other modules to avoid depending on instance-count to stay safe.
  wire [AGE_W-1:0] age0 = a_rdata_i[0][AGE_W-1:0];
  wire [AGE_W-1:0] age1 = a_rdata_i[1][AGE_W-1:0];
  wire [AGE_W-1:0] age2 = a_rdata_i[2][AGE_W-1:0];
  wire [AGE_W-1:0] age3 = a_rdata_i[3][AGE_W-1:0];

  wire v0 = (age0 != '0);
  wire v1 = (age1 != '0);
  wire v2 = (age2 != '0);
  wire v3 = (age3 != '0);

  wire m0 = v0 && (a_rdata_i[0][ENTRY_W-1 -: MAC_W] == mac_q);
  wire m1 = v1 && (a_rdata_i[1][ENTRY_W-1 -: MAC_W] == mac_q);
  wire m2 = v2 && (a_rdata_i[2][ENTRY_W-1 -: MAC_W] == mac_q);
  wire m3 = v3 && (a_rdata_i[3][ENTRY_W-1 -: MAC_W] == mac_q);

  wire match_found = m0 | m1 | m2 | m3;
  wire any_empty   = !(v0 && v1 && v2 && v3);

  logic [1:0]            match_idx, empty_idx, chosen_idx;
  logic [1:0]            oldest01, oldest23, oldest_idx;
  logic [AGE_W-1:0]      age01, age23;
  logic [PORTMASK_W-1:0] port_mask_onehot;

  always_comb begin
    if      (m0) match_idx = 2'd0;
    else if (m1) match_idx = 2'd1;
    else if (m2) match_idx = 2'd2;
    else         match_idx = 2'd3;

    if      (!v0) empty_idx = 2'd0;
    else if (!v1) empty_idx = 2'd1;
    else if (!v2) empty_idx = 2'd2;
    else          empty_idx = 2'd3;

    // smallest age among the valid (non-empty) ways, as a small tournament
    // (only meaningful when !any_empty, i.e. all four ways are valid)
    if      (age0 <= age1) begin oldest01 = 2'd0; age01 = age0; end
    else                    begin oldest01 = 2'd1; age01 = age1; end
    if      (age2 <= age3) begin oldest23 = 2'd2; age23 = age2; end
    else                    begin oldest23 = 2'd3; age23 = age3; end
    if (age01 <= age23) oldest_idx = oldest01;
    else                 oldest_idx = oldest23;

    if (match_found)    chosen_idx = match_idx;
    else if (any_empty) chosen_idx = empty_idx;
    else                chosen_idx = oldest_idx;

    port_mask_onehot = PORTMASK_W'(1) << port_id_q;
  end

  always_comb begin
    state_d      = state_q;
    fifo_rd_en_o = 1'b0;
    bus_req_o    = (state_q != S_IDLE);
    a_en_o       = '0;
    a_we_o       = '0;
    a_addr_o     = hash_q;
    a_wdata_o    = {mac_q, port_mask_onehot, default_age_i};

    unique case (state_q)
      S_IDLE: begin
        if (!fifo_empty_i) state_d = S_REQ;
      end
      S_REQ: begin
        if (bus_gnt_i) state_d = S_POP;
      end
      S_POP: begin
        fifo_rd_en_o = 1'b1;
        a_addr_o     = fifo_hash;
        a_en_o       = '1; // read all 4 ways at this index
        state_d      = S_READ_LAT;
      end
      S_READ_LAT: begin
        // hold: a_en_o stays 0 (default) so a_rdata_i keeps the value
        // registered during S_POP, stable for the decision logic above
        state_d = S_WRITE;
      end
      S_WRITE: begin
        // whole-vector shift rather than a variable-indexed bit-select write
        a_en_o  = NUM_BANKS'(1) << chosen_idx;
        a_we_o  = a_en_o;
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
