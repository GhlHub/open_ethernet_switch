// mac_table_pkg.sv
//
// Shared parameters, types and the MAC->hash function for the MAC address
// aging table. Change the port counts / RAM geometry here; everything else
// in rtl/mac_table derives its widths from this package.

package mac_table_pkg;

  // ---------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------
  parameter int NUM_LEARN_PORTS  = 8;   // up to 8 MAC learning ports
  parameter int NUM_LOOKUP_PORTS = 8;   // up to 8 MAC lookup ports
  parameter int NUM_BANKS        = 4;   // 4-way associative hash table
  parameter int BANK_DEPTH       = 512; // 512 entries per bank
  parameter int BANK_ADDR_W      = 9;   // $clog2(BANK_DEPTH) -- fixed at 9 to
                                         // match "lower 9 bits of the CRC"

  parameter int MAC_W      = 48;  // 48-bit MAC address
  parameter int PORTMASK_W = 8;   // up to 8-bit port mask
  parameter int AGE_W      = 9;   // 9-bit time-remaining-until-expiration

  parameter int LEARN_ID_W  = (NUM_LEARN_PORTS  > 1) ? $clog2(NUM_LEARN_PORTS)  : 1;
  parameter int LOOKUP_ID_W = (NUM_LOOKUP_PORTS > 1) ? $clog2(NUM_LOOKUP_PORTS) : 1;

  // request FIFOs sitting behind the port-side arbiters
  parameter int LEARN_FIFO_DEPTH  = 16;
  parameter int LOOKUP_FIFO_DEPTH = 16;

  parameter int LEARN_FIFO_W  = MAC_W + LEARN_ID_W  + BANK_ADDR_W;
  parameter int LOOKUP_FIFO_W = MAC_W + LOOKUP_ID_W + BANK_ADDR_W;

  // suggested reset/default aging value in seconds; mac_addr_table_top
  // instead takes this as a runtime input (default_age_i) so software can
  // configure it, this constant is only a documentation default.
  parameter logic [AGE_W-1:0] DEFAULT_AGE_RESET = 9'd300;

  // ---------------------------------------------------------------------
  // Aging sweep schedule
  //
  // The external aging tick (age_tick_i, expected ~4 Hz / 250ms period)
  // ages only one quadrant (1/AGE_TICKS_PER_SWEEP) of a bank's BANK_DEPTH
  // entries per pulse, round-robining across quadrants so the whole bank
  // is aged once every AGE_TICKS_PER_SWEEP ticks (~1 second at 4 Hz). Both
  // BANK_DEPTH and AGE_TICKS_PER_SWEEP must be powers of two so the
  // quadrant select is simply the upper bits of the row address and the
  // in-quadrant offset the lower bits (no multiply/divide needed).
  // ---------------------------------------------------------------------
  parameter int AGE_TICKS_PER_SWEEP = 4;
  parameter int AGE_QUAD_SEL_W      = $clog2(AGE_TICKS_PER_SWEEP);
  parameter int AGE_QUAD_ADDR_W     = BANK_ADDR_W - AGE_QUAD_SEL_W;
  parameter int AGE_QUAD_DEPTH      = 1 << AGE_QUAD_ADDR_W;

  // ---------------------------------------------------------------------
  // Table entry
  //
  // Represented as a flat bit vector {mac, port_mask, age} (mac in the MSBs)
  // rather than a packed struct: Icarus Verilog 12.0 (used for simulation
  // of this design) crashes when an unpacked array of packed structs is
  // indexed with a variable/constant index and then field-selected in the
  // same expression (`arr[w].field`). Plain part-selects on a flat vector
  // have no such problem and are exactly as synthesizable.
  // ---------------------------------------------------------------------
  parameter int ENTRY_W = MAC_W + PORTMASK_W + AGE_W;

  // NOTE: these accessor functions are provided for testbenches and
  // documentation, but are deliberately NOT called from any synthesizable
  // module in rtl/mac_table. Icarus Verilog 12.0 has a confirmed bug where
  // the same package-scope `function automatic`, called every cycle from
  // more than one module instance running in lockstep, corrupts simulation
  // (verified with a minimal reproduction: it only appears with >=2
  // instances of the calling module plus a real non-zero write, and
  // disappears when the identical bit-slicing is inlined instead). Since
  // aging_sweep_fsm is instantiated NUM_BANKS times and mac_learn_port/
  // mac_lookup_port NUM_LEARN_PORTS/NUM_LOOKUP_PORTS times, every RTL
  // module inlines this same field access/hash logic directly rather than
  // calling these functions. Keep any future RTL consistent with that.
  function automatic logic [ENTRY_W-1:0] make_entry(
    input logic [MAC_W-1:0]      mac,
    input logic [PORTMASK_W-1:0] port_mask,
    input logic [AGE_W-1:0]      age
  );
    return {mac, port_mask, age};
  endfunction

  function automatic logic [MAC_W-1:0] entry_mac(input logic [ENTRY_W-1:0] e);
    return e[ENTRY_W-1 -: MAC_W];
  endfunction

  function automatic logic [PORTMASK_W-1:0] entry_port_mask(input logic [ENTRY_W-1:0] e);
    return e[AGE_W +: PORTMASK_W];
  endfunction

  function automatic logic [AGE_W-1:0] entry_age(input logic [ENTRY_W-1:0] e);
    return e[AGE_W-1:0];
  endfunction

  // age == 0 means the slot is empty/unused
  function automatic logic entry_empty(input logic [ENTRY_W-1:0] e);
    return (entry_age(e) == '0);
  endfunction

  // ---------------------------------------------------------------------
  // MAC -> BANK_ADDR_W hash
  //
  // Bit-serial CRC-9 (poly 9'h11B), MSB-first over the 48 MAC bits. This is
  // *not* a standards CRC -- the polynomial was picked only for reasonable
  // bit mixing/avalanche so the 512 buckets fill evenly. BANK_ADDR_W is
  // expected to stay 9 to match the 4x512-entry RAM structure this hash
  // feeds.
  // ---------------------------------------------------------------------
  function automatic logic [BANK_ADDR_W-1:0] mac_hash9(input logic [MAC_W-1:0] mac);
    logic [BANK_ADDR_W-1:0] crc;
    logic                   fb;
    crc = {BANK_ADDR_W{1'b1}};
    for (int i = 0; i < MAC_W; i++) begin
      fb  = crc[BANK_ADDR_W-1] ^ mac[i];
      crc = {crc[BANK_ADDR_W-2:0], 1'b0};
      if (fb) crc = crc ^ 9'h11B;
    end
    return crc;
  endfunction

endpackage
