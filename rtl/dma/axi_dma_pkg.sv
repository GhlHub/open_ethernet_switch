// axi_dma_pkg.sv
//
// Parameters for the AXI4 DMA engines that move frame payload bytes
// to/from PS DDR on behalf of buf_mgr_core. Imports buf_mgr_pkg for
// buffer geometry (BUF_ID_W, BUFFER_BYTES, LENGTH_W) so the two stay
// consistent by construction.
//
// Scope: 5 physical ports (PS x2, PL x2, SFP) each get a DMA front-end
// sharing the arbitrated engines in this package's NUM_PHYS_PORTS-wide
// modules (ingress_dma_wr.sv/egress_dma_rd.sv). The CPU port
// (buf_mgr_pkg::NUM_PORTS' 6th port) is symmetric with these at the
// buf_mgr_core/AXI4-Stream level (same ingress_port_wr.sv/
// egress_port_rd.sv modules, PORT_ID=5) but gets its own dedicated,
// non-arbitrated DMA engines instead of sharing these ones -- see
// rtl/cpu_port/cpu_dma_wr.sv and cpu_dma_rd.sv -- fed by a Vivado-
// configured AXI DMA IP (Scatter/Gather mode) on the CPU's Linux network
// stack side, not the AXI4-Stream-facing MAC these engines serve.

package axi_dma_pkg;

  import buf_mgr_pkg::BUF_ID_W;
  import buf_mgr_pkg::BUFFER_BYTES;
  import buf_mgr_pkg::LENGTH_W;
  import buf_mgr_pkg::NUM_PORTS;
  import buf_mgr_pkg::PORT_ID_W;

  parameter int NUM_PHYS_PORTS = 5; // PS0, PS1, PL0, PL1, SFP0 (ports 0-4 of buf_mgr_pkg::NUM_PORTS)

  // rr_arbiter (rtl/common) requires a power-of-two N; NUM_PHYS_PORTS=5 is
  // not one, so arbiters here are instantiated at DMA_ARB_N with the
  // upper (DMA_ARB_N-NUM_PHYS_PORTS) request bits permanently tied to 0 --
  // same convention as buf_mgr_pkg::ARB_N (named differently here since a
  // module that imports both packages' wildcards would otherwise see an
  // ambiguous "ARB_N").
  parameter int DMA_ARB_N = 1 << $clog2(NUM_PHYS_PORTS);

  // ---------------------------------------------------------------------
  // AXI4 bus parameters. 128-bit data width is the width recommended
  // earlier for saturating a PS HP/HPC port's share of DDR bandwidth;
  // ADDR_W and the DDR base are build-time constants for wherever the
  // reserved buffer-pool region of PS DDR is mapped.
  // ---------------------------------------------------------------------
  parameter int AXI_ADDR_W = 32;
  parameter int AXI_DATA_W = 128;
  parameter int AXI_STRB_W = AXI_DATA_W / 8;
  parameter int AXI_ID_W   = 1; // tied to 0: engines are single-outstanding-transaction

  parameter logic [AXI_ADDR_W-1:0] DDR_BASE_ADDR = 32'h1000_0000;

  // BUFFER_BYTES must be a multiple of AXI_STRB_W (true for the default
  // 2048/16) so a buffer's beat count divides evenly with no remainder
  // logic needed for the "full buffer" case; per-frame burst length is
  // still computed from the actual frame length, not this max.
  parameter int BEATS_PER_BUFFER = BUFFER_BYTES / AXI_STRB_W;
  parameter int BEAT_IDX_W       = $clog2(BEATS_PER_BUFFER);

  // NOTE (same rationale as rtl/mac_table and rtl/buf_mgr): these are for
  // testbenches and documentation only, never called from synthesizable
  // RTL. ingress_port_wr.sv/egress_port_rd.sv are each instantiated
  // NUM_PHYS_PORTS (5) times -- exactly the condition that triggers
  // Icarus Verilog 12.0's confirmed bug where a package-scope `function
  // automatic`, called every cycle from more than one instance of the
  // calling module, corrupts simulation. Every RTL module inlines the
  // equivalent arithmetic directly instead.
  function automatic int unsigned beats_for_length(input logic [LENGTH_W-1:0] length);
    return (int'(length) + AXI_STRB_W - 1) / AXI_STRB_W;
  endfunction

  function automatic logic [AXI_ADDR_W-1:0] buffer_addr(input logic [BUF_ID_W-1:0] bufid);
    return DDR_BASE_ADDR + (AXI_ADDR_W'(bufid) * AXI_ADDR_W'(BUFFER_BYTES));
  endfunction

endpackage
