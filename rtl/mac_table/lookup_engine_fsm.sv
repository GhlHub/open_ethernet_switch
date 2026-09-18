// lookup_engine_fsm.sv
//
// Fully pipelined lookup datapath. This engine owns bank port B exclusively
// -- lookup never writes and never shares this port with anything else (the
// learn engine and aging share port A instead, arbitrated separately) -- so
// there is no bus arbitration here at all, and a new lookup can be issued
// every single cycle the request FIFO is non-empty:
//
//   cycle N   : pop the FIFO, issue a read (b_addr_o/b_en_o) to all 4 banks
//               at the hash index, and latch {mac, req_id} into the stage-1
//               pipeline register
//   cycle N+1 : the bank's registered read data (b_rdata_i) is now valid
//               for that address; combinationally decide hit/way and drive
//               result_valid_o/result_req_id_o/result_hit_o/
//               result_port_mask_o for that request (a further pipeline
//               register inside mac_lookup_port captures this before it
//               reaches the requesting port, exactly as before)
//
// Steady-state throughput is therefore 1 completed lookup/cycle whenever
// the FIFO has a backlog, with the same ~2-cycle latency through this
// engine (address issue -> decode) that a single request always had --
// the difference from the old design is that engine is no longer idle in
// between: many lookups are in flight (one per stage) at once.

module lookup_engine_fsm
  import mac_table_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic                     fifo_empty_i,
  input  logic [LOOKUP_FIFO_W-1:0] fifo_rd_data_i,
  output logic                     fifo_rd_en_o,

  output logic [NUM_BANKS-1:0]   b_en_o,
  output logic [BANK_ADDR_W-1:0] b_addr_o,
  input  logic [ENTRY_W-1:0]     b_rdata_i [NUM_BANKS],

  output logic                   result_valid_o,
  output logic [LOOKUP_ID_W-1:0] result_req_id_o,
  output logic                   result_hit_o,
  output logic [PORTMASK_W-1:0]  result_port_mask_o
);

  wire [MAC_W-1:0]        fifo_mac  = fifo_rd_data_i[LOOKUP_FIFO_W-1 -: MAC_W];
  wire [LOOKUP_ID_W-1:0]  fifo_rid  = fifo_rd_data_i[BANK_ADDR_W +: LOOKUP_ID_W];
  wire [BANK_ADDR_W-1:0]  fifo_hash = fifo_rd_data_i[BANK_ADDR_W-1:0];

  // ---- stage 0: issue (combinational, every cycle the FIFO has data) ----
  wire issue = !fifo_empty_i;

  assign fifo_rd_en_o = issue;
  assign b_en_o        = {NUM_BANKS{issue}};
  assign b_addr_o      = fifo_hash;

  // ---- stage 0 -> stage 1 pipeline register ----
  logic                   stage1_valid_q;
  logic [MAC_W-1:0]       stage1_mac_q;
  logic [LOOKUP_ID_W-1:0] stage1_req_id_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage1_valid_q  <= 1'b0;
      stage1_mac_q    <= '0;
      stage1_req_id_q <= '0;
    end else begin
      stage1_valid_q <= issue;
      if (issue) begin
        stage1_mac_q    <= fifo_mac;
        stage1_req_id_q <= fifo_rid;
      end
    end
  end

  // ---- stage 1: decide (combinational; b_rdata_i now valid for the
  // address issued last cycle, stage1_mac_q/req_id_q describe that request)
  //
  // NUM_BANKS is architecturally fixed at 4 (the spec's "4 x 512-entry
  // RAMs"), so the 4 ways are handled with explicitly named signals rather
  // than a procedural for-loop over an indexed vector/array. Icarus
  // Verilog 12.0 miscompiles a for-loop that writes different bit
  // positions of the same vector across iterations (confirmed: it silently
  // corrupts the result). Field access is also inlined rather than calling
  // the mac_table_pkg entry_empty/entry_mac/entry_port_mask functions --
  // see the note in aging_sweep_fsm.sv for why RTL avoids calling those
  // package functions.
  wire v0 = (b_rdata_i[0][AGE_W-1:0] != '0);
  wire v1 = (b_rdata_i[1][AGE_W-1:0] != '0);
  wire v2 = (b_rdata_i[2][AGE_W-1:0] != '0);
  wire v3 = (b_rdata_i[3][AGE_W-1:0] != '0);

  wire m0 = v0 && (b_rdata_i[0][ENTRY_W-1 -: MAC_W] == stage1_mac_q);
  wire m1 = v1 && (b_rdata_i[1][ENTRY_W-1 -: MAC_W] == stage1_mac_q);
  wire m2 = v2 && (b_rdata_i[2][ENTRY_W-1 -: MAC_W] == stage1_mac_q);
  wire m3 = v3 && (b_rdata_i[3][ENTRY_W-1 -: MAC_W] == stage1_mac_q);

  wire match_found = m0 | m1 | m2 | m3;

  logic [1:0]            match_idx;
  logic [PORTMASK_W-1:0] matched_port_mask;

  always_comb begin
    if      (m0) match_idx = 2'd0;
    else if (m1) match_idx = 2'd1;
    else if (m2) match_idx = 2'd2;
    else         match_idx = 2'd3;

    unique case (match_idx)
      2'd0: matched_port_mask = b_rdata_i[0][AGE_W +: PORTMASK_W];
      2'd1: matched_port_mask = b_rdata_i[1][AGE_W +: PORTMASK_W];
      2'd2: matched_port_mask = b_rdata_i[2][AGE_W +: PORTMASK_W];
      default: matched_port_mask = b_rdata_i[3][AGE_W +: PORTMASK_W];
    endcase
  end

  assign result_valid_o     = stage1_valid_q;
  assign result_req_id_o    = stage1_req_id_q;
  assign result_hit_o       = match_found;
  assign result_port_mask_o = match_found ? matched_port_mask : '0;

endmodule
