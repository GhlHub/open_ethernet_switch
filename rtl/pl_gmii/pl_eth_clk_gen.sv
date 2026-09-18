// pl_eth_clk_gen.sv
//
// Per-PL-port clock generator: one 25MHz board oscillator tap in
// (`ref_clk_25m_i` -- see rgmii_gmii_adapter.sv's header for where this
// actually comes from on the real board: one of four buffered taps off
// a single shared oscillator, confirmed via the real KR260 carrier
// schematic), three clocks out -- 125MHz (`gtx_clk_o`, GMII-side, shared
// by pl_gmii_mac_top.sv and rgmii_gmii_adapter.sv's TX/RX domain),
// 300MHz (`idelay_refclk_o`, rgmii_gmii_adapter.sv's IDELAYE3/
// IDELAYCTRL reference), and 62.5MHz (`clk_o`). One instance per PL
// port -- IDELAYCTRL's calibration domain is bank-local (see
// rgmii_gmii_adapter.sv's header), PL0 and PL1 are in different I/O
// banks, so there is no benefit to (and no real way to) share a single
// instance across both ports for gtx_clk_o/idelay_refclk_o.
//
// clk_o (62.5MHz) is a different story: switch_top.sv's `clk` is the
// single switch fabric clock shared by *everything* (ingress/egress,
// buf_mgr_core, the MAC table, the CPU port, both PL ports, SFP -- not
// scoped to one port the way gtx_clk_o/idelay_refclk_o are), so only
// ONE instance's clk_o is meant to actually be used for that -- by
// explicit choice, the PL0 instance's. The PL1 instance still generates
// its own clk_o (this module doesn't have a variant without it -- one
// IP configuration, two uses), it's just left unconnected by whatever
// instantiates both. Documented here, not enforced by the RTL itself.
//
// Wraps rtl/pl_gmii/ip/pl_eth_clk_gen_ip.xci, a Vivado `clk_wiz`
// (Clocking Wizard) IP core -- generated and validated against
// xck26-sfvc784-2LV-c rather than hand-computed (MMCM multiply/divide
// values aren't something to guess at): all three output frequencies
// land exactly on target (125.00000 MHz, 300.00000 MHz, 62.50000 MHz),
// confirmed by the tool, not assumed. Regenerate
// rtl/pl_gmii/ip/pl_eth_clk_gen_ip.xci's output products in Vivado
// before synthesis/simulation of this file; only the .xci itself is
// meant to be checked in.
//
// gtx_rst_n_o/idelay_refclk_rst_n_o/rst_n_o are each a small reset
// synchronizer (async assert on MMCM unlock, synchronous release 2
// cycles after lock) releasing into their own respective output clock
// domain -- the same pattern used throughout this project for a
// PLL/MMCM-style lock signal (e.g. gth_sfp_wrapper.sv's gth_rst_n_o).

module pl_eth_clk_gen (
  input  logic ref_clk_25m_i, // board oscillator tap (see header)
  input  logic rst_n_i,       // async system reset in

  output logic gtx_clk_o,           // 125 MHz
  output logic gtx_rst_n_o,         // synchronized to gtx_clk_o

  output logic idelay_refclk_o,       // 300 MHz
  output logic idelay_refclk_rst_n_o, // synchronized to idelay_refclk_o

  output logic clk_o,       // 62.5 MHz -- see header: PL0 instance only
  output logic rst_n_o,     // synchronized to clk_o

  output logic locked_o // raw MMCM lock status, informational
);

  wire locked;
  assign locked_o = locked;

  pl_eth_clk_gen_ip u_clk_wiz (
    .clk_in1  (ref_clk_25m_i),
    .resetn   (rst_n_i),
    .clk_out1 (gtx_clk_o),
    .clk_out2 (idelay_refclk_o),
    .clk_out3 (clk_o),
    .locked   (locked)
  );

  logic [1:0] gtx_rst_sync_q;
  always_ff @(posedge gtx_clk_o or negedge locked) begin
    if (!locked) gtx_rst_sync_q <= 2'b00;
    else         gtx_rst_sync_q <= {gtx_rst_sync_q[0], 1'b1};
  end
  assign gtx_rst_n_o = gtx_rst_sync_q[1];

  logic [1:0] idelay_rst_sync_q;
  always_ff @(posedge idelay_refclk_o or negedge locked) begin
    if (!locked) idelay_rst_sync_q <= 2'b00;
    else         idelay_rst_sync_q <= {idelay_rst_sync_q[0], 1'b1};
  end
  assign idelay_refclk_rst_n_o = idelay_rst_sync_q[1];

  logic [1:0] clk_rst_sync_q;
  always_ff @(posedge clk_o or negedge locked) begin
    if (!locked) clk_rst_sync_q <= 2'b00;
    else         clk_rst_sync_q <= {clk_rst_sync_q[0], 1'b1};
  end
  assign rst_n_o = clk_rst_sync_q[1];

endmodule
