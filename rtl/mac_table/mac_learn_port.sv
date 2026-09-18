// mac_learn_port.sv
//
// One instance per MAC learning port (PORT_ID = 0..NUM_LEARN_PORTS-1).
// Latches (mac, source port) on a request pulse and holds a request to the
// top-level round-robin arbiter until granted, at which point its
// (mac, port_id, hash) is pushed into the learn FIFO. A new learn_req_i
// while a request is already pending/busy is dropped -- the caller should
// watch busy_o.

module mac_learn_port
  import mac_table_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic             clk,
  input  logic             rst_n,

  input  logic              learn_req_i,
  input  logic [MAC_W-1:0]  mac_i,
  output logic              busy_o,

  output logic                    arb_req_o,
  input  logic                    arb_grant_i,
  output logic [MAC_W-1:0]        fifo_mac_o,
  output logic [LEARN_ID_W-1:0]   fifo_port_id_o,
  output logic [BANK_ADDR_W-1:0]  fifo_hash_o
);

  logic                pending_q;
  logic [MAC_W-1:0]    mac_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_q <= 1'b0;
      mac_q     <= '0;
    end else if (learn_req_i && !pending_q) begin
      pending_q <= 1'b1;
      mac_q     <= mac_i;
    end else if (arb_grant_i && pending_q) begin
      pending_q <= 1'b0;
    end
  end

  assign busy_o         = pending_q;
  assign arb_req_o      = pending_q;
  assign fifo_mac_o     = mac_q;
  assign fifo_port_id_o = LEARN_ID_W'(PORT_ID);

  // Hash computed inline (rather than calling mac_table_pkg::mac_hash9())
  // because this module is instantiated NUM_LEARN_PORTS times: Icarus
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

endmodule
