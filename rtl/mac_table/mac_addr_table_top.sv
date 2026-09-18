// mac_addr_table_top.sv
//
// Top-level MAC address aging table for the KR260 smart network auditor
// switch design.
//
//   - up to NUM_LEARN_PORTS (8) MAC learning ports: each latches
//     (mac, source port) and arbitrates into a shared learn request FIFO
//   - up to NUM_LOOKUP_PORTS (8) MAC lookup ports: each latches mac,
//     arbitrates into a shared lookup request FIFO, and later gets its
//     hit/port_mask result back
//   - a 4-way set-associative table: MAC -> 9-bit CRC hash selects one of
//     512 rows in each of 4 independent 512-entry RAM banks
//
// Bank port allocation:
//   - Port A is shared between the learn engine and that bank's own
//     aging_sweep_fsm, arbitrated per bank by bank_arbiter (learn has
//     fixed priority; aging yields the bus every entry so it never blocks
//     learn for more than a couple of cycles -- see bank_arbiter.sv and
//     aging_sweep_fsm.sv). Learn addresses all 4 banks identically (one
//     hash index, 4-way associative decision), so it only proceeds once
//     every bank's arbiter has granted it -- learn_bus_gnt below is the
//     AND of all NUM_BANKS per-bank grants. Aging is independent per bank
//     and only needs its own bank's grant.
//   - Port B is dedicated exclusively to the lookup engine: no arbitration
//     at all, which is what lets lookup_engine_fsm be a free-running
//     2-stage pipeline (issue address -> decide next cycle) instead of a
//     multi-cycle sequential FSM, for up to 1 lookup issued per cycle.
//
// aging_sweep_fsm sweeps one quadrant (1/AGE_TICKS_PER_SWEEP, 128 entries
// by default) of its bank on every age_tick_i pulse (expected ~4 Hz),
// decrementing non-zero ages; the whole bank is aged once every
// AGE_TICKS_PER_SWEEP ticks (~1 second).
//
// default_age_i is the time-remaining value (seconds) written into a newly
// learned/refreshed entry; it is a runtime input rather than a fixed
// constant so it can be made software-configurable elsewhere in the design.

module mac_addr_table_top
  import mac_table_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // aging tick: nominally ~4 Hz (each pulse ages one quadrant of each
  // bank; the whole bank is aged once every AGE_TICKS_PER_SWEEP pulses).
  // Need not already be a clean single-cycle pulse in this clock domain --
  // it is synchronized and edge-detected below.
  input  logic age_tick_i,

  input  logic [AGE_W-1:0] default_age_i,

  // learning ports
  input  logic [NUM_LEARN_PORTS-1:0]            learn_req_i,
  input  logic [NUM_LEARN_PORTS-1:0][MAC_W-1:0] learn_mac_i,
  output logic [NUM_LEARN_PORTS-1:0]            learn_busy_o,

  // lookup ports
  input  logic [NUM_LOOKUP_PORTS-1:0]                lookup_req_i,
  input  logic [NUM_LOOKUP_PORTS-1:0][MAC_W-1:0]     lookup_mac_i,
  output logic [NUM_LOOKUP_PORTS-1:0]                lookup_busy_o,
  output logic [NUM_LOOKUP_PORTS-1:0]                lookup_result_valid_o,
  output logic [NUM_LOOKUP_PORTS-1:0]                lookup_result_hit_o,
  output logic [NUM_LOOKUP_PORTS-1:0][PORTMASK_W-1:0] lookup_result_port_mask_o
);

  genvar gi;

  // -----------------------------------------------------------------
  // Aging tick synchronizer + rising-edge detector
  // -----------------------------------------------------------------
  logic tick_meta, tick_sync_q, tick_sync_q2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tick_meta    <= 1'b0;
      tick_sync_q  <= 1'b0;
      tick_sync_q2 <= 1'b0;
    end else begin
      tick_meta    <= age_tick_i;
      tick_sync_q  <= tick_meta;
      tick_sync_q2 <= tick_sync_q;
    end
  end
  wire age_tick_pulse = tick_sync_q & ~tick_sync_q2;

  // -----------------------------------------------------------------
  // Learn side: ports -> round-robin arbiter -> FIFO -> learn_engine_fsm
  // -----------------------------------------------------------------
  logic [NUM_LEARN_PORTS-1:0]                 learn_pending, learn_grant;
  logic [NUM_LEARN_PORTS-1:0][MAC_W-1:0]      learn_port_mac;
  logic [NUM_LEARN_PORTS-1:0][LEARN_ID_W-1:0] learn_port_pid;
  logic [NUM_LEARN_PORTS-1:0][BANK_ADDR_W-1:0] learn_port_hash;
  logic learn_arb_valid, learn_fifo_full, learn_fifo_empty, learn_fifo_rd_en;
  logic [LEARN_FIFO_W-1:0] learn_fifo_wr_data, learn_fifo_rd_data;

  generate
    for (gi = 0; gi < NUM_LEARN_PORTS; gi++) begin : g_learn_ports
      mac_learn_port #(.PORT_ID(gi)) u_learn_port (
        .clk            (clk),
        .rst_n          (rst_n),
        .learn_req_i    (learn_req_i[gi]),
        .mac_i          (learn_mac_i[gi]),
        .busy_o         (learn_busy_o[gi]),
        .arb_req_o      (learn_pending[gi]),
        .arb_grant_i    (learn_grant[gi]),
        .fifo_mac_o     (learn_port_mac[gi]),
        .fifo_port_id_o (learn_port_pid[gi]),
        .fifo_hash_o    (learn_port_hash[gi])
      );
    end
  endgenerate

  rr_arbiter #(.N(NUM_LEARN_PORTS)) u_learn_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   (learn_pending & {NUM_LEARN_PORTS{~learn_fifo_full}}),
    .grant_o (learn_grant),
    .valid_o (learn_arb_valid)
  );

  always_comb begin
    learn_fifo_wr_data = '0;
    for (int p = 0; p < NUM_LEARN_PORTS; p++) begin
      if (learn_grant[p]) begin
        learn_fifo_wr_data = {learn_port_mac[p], learn_port_pid[p], learn_port_hash[p]};
      end
    end
  end

  sync_fifo #(.WIDTH(LEARN_FIFO_W), .DEPTH(LEARN_FIFO_DEPTH)) u_learn_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en_i   (learn_arb_valid),
    .wr_data_i (learn_fifo_wr_data),
    .full_o    (learn_fifo_full),
    .rd_en_i   (learn_fifo_rd_en),
    .rd_data_o (learn_fifo_rd_data),
    .empty_o   (learn_fifo_empty)
  );

  // -----------------------------------------------------------------
  // Lookup side: ports -> round-robin arbiter -> FIFO -> lookup_engine_fsm
  // -----------------------------------------------------------------
  logic [NUM_LOOKUP_PORTS-1:0]                  lookup_pending, lookup_grant;
  logic [NUM_LOOKUP_PORTS-1:0][MAC_W-1:0]       lookup_port_mac;
  logic [NUM_LOOKUP_PORTS-1:0][LOOKUP_ID_W-1:0] lookup_port_rid;
  logic [NUM_LOOKUP_PORTS-1:0][BANK_ADDR_W-1:0] lookup_port_hash;
  logic lookup_arb_valid, lookup_fifo_full, lookup_fifo_empty, lookup_fifo_rd_en;
  logic [LOOKUP_FIFO_W-1:0] lookup_fifo_wr_data, lookup_fifo_rd_data;

  logic                   result_valid_eng;
  logic [LOOKUP_ID_W-1:0] result_req_id_eng;
  logic                   result_hit_eng;
  logic [PORTMASK_W-1:0]  result_port_mask_eng;
  logic [NUM_LOOKUP_PORTS-1:0] result_valid_demux;

  generate
    for (gi = 0; gi < NUM_LOOKUP_PORTS; gi++) begin : g_lookup_ports
      mac_lookup_port #(.PORT_ID(gi)) u_lookup_port (
        .clk                 (clk),
        .rst_n               (rst_n),
        .lookup_req_i        (lookup_req_i[gi]),
        .mac_i               (lookup_mac_i[gi]),
        .busy_o              (lookup_busy_o[gi]),
        .arb_req_o           (lookup_pending[gi]),
        .arb_grant_i         (lookup_grant[gi]),
        .fifo_mac_o          (lookup_port_mac[gi]),
        .fifo_req_id_o       (lookup_port_rid[gi]),
        .fifo_hash_o         (lookup_port_hash[gi]),
        .result_valid_i      (result_valid_demux[gi]),
        .result_hit_i        (result_hit_eng),
        .result_port_mask_i  (result_port_mask_eng),
        .result_valid_o      (lookup_result_valid_o[gi]),
        .result_hit_o        (lookup_result_hit_o[gi]),
        .result_port_mask_o  (lookup_result_port_mask_o[gi])
      );
    end
  endgenerate

  always_comb begin
    result_valid_demux = '0;
    if (result_valid_eng) result_valid_demux[result_req_id_eng] = 1'b1;
  end

  rr_arbiter #(.N(NUM_LOOKUP_PORTS)) u_lookup_arb (
    .clk     (clk),
    .rst_n   (rst_n),
    .req_i   (lookup_pending & {NUM_LOOKUP_PORTS{~lookup_fifo_full}}),
    .grant_o (lookup_grant),
    .valid_o (lookup_arb_valid)
  );

  always_comb begin
    lookup_fifo_wr_data = '0;
    for (int p = 0; p < NUM_LOOKUP_PORTS; p++) begin
      if (lookup_grant[p]) begin
        lookup_fifo_wr_data = {lookup_port_mac[p], lookup_port_rid[p], lookup_port_hash[p]};
      end
    end
  end

  sync_fifo #(.WIDTH(LOOKUP_FIFO_W), .DEPTH(LOOKUP_FIFO_DEPTH)) u_lookup_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en_i   (lookup_arb_valid),
    .wr_data_i (lookup_fifo_wr_data),
    .full_o    (lookup_fifo_full),
    .rd_en_i   (lookup_fifo_rd_en),
    .rd_data_o (lookup_fifo_rd_data),
    .empty_o   (lookup_fifo_empty)
  );

  // -----------------------------------------------------------------
  // The two drain engines. learn_bus_req is broadcast identically to all
  // NUM_BANKS per-bank arbiters (instantiated below, inside g_banks);
  // learn_bus_gnt is the AND of all their grants. Lookup has no bus
  // arbitration at all -- it owns port B outright.
  // -----------------------------------------------------------------
  logic learn_bus_req, learn_bus_gnt;
  logic [NUM_BANKS-1:0] learn_gnt_vec;
  assign learn_bus_gnt = &learn_gnt_vec;

  logic [NUM_BANKS-1:0]   learn_a_en, learn_a_we;
  logic [BANK_ADDR_W-1:0] learn_a_addr;
  logic [ENTRY_W-1:0]     learn_a_wdata;

  logic [NUM_BANKS-1:0]   lookup_b_en;
  logic [BANK_ADDR_W-1:0] lookup_b_addr;

  logic [ENTRY_W-1:0] bank_b_rdata [NUM_BANKS];
  logic [ENTRY_W-1:0] bank_a_rdata [NUM_BANKS];

  learn_engine_fsm u_learn_engine (
    .clk            (clk),
    .rst_n          (rst_n),
    .default_age_i  (default_age_i),
    .fifo_empty_i   (learn_fifo_empty),
    .fifo_rd_data_i (learn_fifo_rd_data),
    .fifo_rd_en_o   (learn_fifo_rd_en),
    .bus_req_o      (learn_bus_req),
    .bus_gnt_i      (learn_bus_gnt),
    .a_en_o         (learn_a_en),
    .a_we_o         (learn_a_we),
    .a_addr_o       (learn_a_addr),
    .a_wdata_o      (learn_a_wdata),
    .a_rdata_i      (bank_a_rdata)
  );

  lookup_engine_fsm u_lookup_engine (
    .clk                (clk),
    .rst_n              (rst_n),
    .fifo_empty_i       (lookup_fifo_empty),
    .fifo_rd_data_i     (lookup_fifo_rd_data),
    .fifo_rd_en_o       (lookup_fifo_rd_en),
    .b_en_o             (lookup_b_en),
    .b_addr_o           (lookup_b_addr),
    .b_rdata_i          (bank_b_rdata),
    .result_valid_o     (result_valid_eng),
    .result_req_id_o    (result_req_id_eng),
    .result_hit_o       (result_hit_eng),
    .result_port_mask_o (result_port_mask_eng)
  );

  // -----------------------------------------------------------------
  // 4 banks. Port A is muxed per bank between the (broadcast) learn
  // engine and that bank's own aging_sweep_fsm by a dedicated
  // bank_arbiter instance; port B is wired straight to the lookup
  // engine's pipeline outputs, no arbitration.
  // -----------------------------------------------------------------
  generate
    for (gi = 0; gi < NUM_BANKS; gi++) begin : g_banks
      logic learn_gnt, aging_gnt;
      logic aging_bus_req;

      logic                   aging_a_en, aging_a_we;
      logic [BANK_ADDR_W-1:0] aging_a_addr;
      logic [ENTRY_W-1:0]     aging_a_wdata;

      logic                   asel_en, asel_we;
      logic [BANK_ADDR_W-1:0] asel_addr;
      logic [ENTRY_W-1:0]     asel_wdata;

      assign asel_en    = learn_gnt ? learn_a_en[gi] : (aging_gnt ? aging_a_en : 1'b0);
      assign asel_we    = learn_gnt ? learn_a_we[gi] : (aging_gnt ? aging_a_we : 1'b0);
      assign asel_addr  = learn_gnt ? learn_a_addr   : aging_a_addr;
      assign asel_wdata = learn_gnt ? learn_a_wdata  : aging_a_wdata;

      assign learn_gnt_vec[gi] = learn_gnt;

      mac_table_bank u_bank (
        .clk       (clk),
        .a_en_i    (asel_en),
        .a_we_i    (asel_we),
        .a_addr_i  (asel_addr),
        .a_wdata_i (asel_wdata),
        .a_rdata_o (bank_a_rdata[gi]),
        .b_en_i    (lookup_b_en[gi]),
        .b_addr_i  (lookup_b_addr),
        .b_rdata_o (bank_b_rdata[gi])
      );

      bank_arbiter u_bank_arb (
        .clk         (clk),
        .rst_n       (rst_n),
        .learn_req_i (learn_bus_req),
        .aging_req_i (aging_bus_req),
        .learn_gnt_o (learn_gnt),
        .aging_gnt_o (aging_gnt)
      );

      aging_sweep_fsm u_aging (
        .clk       (clk),
        .rst_n     (rst_n),
        .tick_i    (age_tick_pulse),
        .bus_req_o (aging_bus_req),
        .bus_gnt_i (aging_gnt),
        .a_en_o    (aging_a_en),
        .a_we_o    (aging_a_we),
        .a_addr_o  (aging_a_addr),
        .a_wdata_o (aging_a_wdata),
        .a_rdata_i (bank_a_rdata[gi])
      );
    end
  endgenerate

endmodule
