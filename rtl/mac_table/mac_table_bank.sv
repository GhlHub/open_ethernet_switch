// mac_table_bank.sv
//
// One 512-entry way of the 4-way associative MAC table. True dual-port RAM:
//   Port A - shared by the learn engine and this bank's aging_sweep_fsm
//            (arbitrated per-bank at the top level, learn has fixed
//            priority); needs read+write since both learn and aging read
//            an entry before deciding whether to write it back
//   Port B - dedicated exclusively to lookup_engine_fsm, read-only. Lookup
//            never writes and never shares this port with anything else,
//            which is what lets it be pipelined for 1 issued lookup/cycle
//            with no arbitration at all.
//
// Both ports are independent, synchronous, 1-cycle read latency (registered
// output), read-first on a same-port read/write collision. This infers as a
// standard Xilinx true dual-port block RAM.
//
// NOTE: port A and port B can legally target the same address in the same
// cycle (e.g. the aging sweep decrementing an entry a lookup is
// simultaneously reading). Both accesses proceed independently and this is
// always safe here since port B never writes -- a lookup racing a port-A
// update simply sees either the old or the new value that same cycle,
// self-corrects on the next lookup, and single-cycle table entries are
// never torn (each is written atomically by port A).

module mac_table_bank
  import mac_table_pkg::*;
(
  input  logic clk,

  // Port A - shared learn/aging read+write port
  input  logic                   a_en_i,
  input  logic                   a_we_i,
  input  logic [BANK_ADDR_W-1:0] a_addr_i,
  input  logic [ENTRY_W-1:0]     a_wdata_i,
  output logic [ENTRY_W-1:0]     a_rdata_o,

  // Port B - dedicated lookup read-only port
  input  logic                   b_en_i,
  input  logic [BANK_ADDR_W-1:0] b_addr_i,
  output logic [ENTRY_W-1:0]     b_rdata_o
);

  logic [ENTRY_W-1:0] mem [0:BANK_DEPTH-1];

  // all entries start empty (age == 0); synthesizes to BRAM initial content
  initial begin
    for (int i = 0; i < BANK_DEPTH; i++) begin
      mem[i] = '0;
    end
  end

  always_ff @(posedge clk) begin
    if (a_en_i) begin
      if (a_we_i) mem[a_addr_i] <= a_wdata_i;
      a_rdata_o <= mem[a_addr_i];
    end
  end

  always_ff @(posedge clk) begin
    if (b_en_i) begin
      b_rdata_o <= mem[b_addr_i];
    end
  end

endmodule
