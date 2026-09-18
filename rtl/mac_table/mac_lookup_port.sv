// mac_lookup_port.sv
//
// One instance per MAC lookup port (PORT_ID = 0..NUM_LOOKUP_PORTS-1).
// Latches mac_i on a request pulse, arbitrates for a slot in the lookup
// FIFO, and later receives its result back from lookup_engine_fsm (routed
// by the top level using result_req_id). The result is held in
// result_hit_o/result_port_mask_o until the next one arrives;
// result_valid_o pulses for one cycle when a fresh result lands.

module mac_lookup_port
  import mac_table_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic             clk,
  input  logic             rst_n,

  input  logic              lookup_req_i,
  input  logic [MAC_W-1:0]  mac_i,
  output logic              busy_o,

  output logic                    arb_req_o,
  input  logic                    arb_grant_i,
  output logic [MAC_W-1:0]        fifo_mac_o,
  output logic [LOOKUP_ID_W-1:0]  fifo_req_id_o,
  output logic [BANK_ADDR_W-1:0]  fifo_hash_o,

  // result delivery, demuxed by requester id at the top level
  input  logic                    result_valid_i,
  input  logic                    result_hit_i,
  input  logic [PORTMASK_W-1:0]   result_port_mask_i,

  output logic                    result_valid_o,
  output logic                    result_hit_o,
  output logic [PORTMASK_W-1:0]   result_port_mask_o
);

  logic             pending_q;
  logic [MAC_W-1:0] mac_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_q <= 1'b0;
      mac_q     <= '0;
    end else if (lookup_req_i && !pending_q) begin
      pending_q <= 1'b1;
      mac_q     <= mac_i;
    end else if (arb_grant_i && pending_q) begin
      pending_q <= 1'b0;
    end
  end

  assign busy_o        = pending_q;
  assign arb_req_o     = pending_q;
  assign fifo_mac_o    = mac_q;
  assign fifo_req_id_o = LOOKUP_ID_W'(PORT_ID);

  // Hash computed inline (rather than calling mac_table_pkg::mac_hash9())
  // because this module is instantiated NUM_LOOKUP_PORTS times: Icarus
  // Verilog 12.0 has a confirmed bug where the same package-scope
  // `function automatic`, called every cycle from more than one module
  // instance, corrupts simulation. See the comment in aging_sweep_fsm.sv
  // for the full writeup; the fix is the same here -- inline the identical
  // bit-serial CRC-9 (poly 9'h11B) instead of calling the shared function.
  logic [BANK_ADDR_W-1:0] hash_crc;
  always_comb begin
    logic [BANK_ADDR_W-1:0] crc;
    logic                   fb;
    crc = {BANK_ADDR_W{1'b1}};
    for (int i = 0; i < MAC_W; i++) begin
      fb  = crc[BANK_ADDR_W-1] ^ mac_q[i];
      crc = {crc[BANK_ADDR_W-2:0], 1'b0};
      if (fb) crc = crc ^ 9'h11B;
    end
    hash_crc = crc;
  end
  assign fifo_hash_o = hash_crc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result_valid_o     <= 1'b0;
      result_hit_o        <= 1'b0;
      result_port_mask_o <= '0;
    end else begin
      result_valid_o <= result_valid_i;
      if (result_valid_i) begin
        result_hit_o       <= result_hit_i;
        result_port_mask_o <= result_port_mask_i;
      end
    end
  end

endmodule
