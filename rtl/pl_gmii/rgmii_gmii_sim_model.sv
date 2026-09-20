// rgmii_gmii_sim_model.sv
//
// Behavioral stand-in for rgmii_gmii_adapter.sv's RGMII<->GMII nibble
// encode/decode logic, for Icarus/Verilator simulation (that file's
// ODDRE1/IDDRE1/IDELAYE3/IDELAYCTRL/BUFG instances are real UltraScale+
// primitives neither tool can simulate -- validated instead by
// elaborating + simulating against Vivado's own xsim + UNISIM models,
// see that file's header). Same RGMII v2.0 encoding rules (low nibble/
// TX_EN on the rising edge, high nibble/TX_EN^TX_ER on the falling
// edge), modeled with plain dual-edge `always @(posedge/negedge ...)`
// blocks instead of DDR I/O primitives -- fine for a non-synthesized
// test stand-in, never fine for the real, synthesizable adapter (see
// that file's header for why explicit primitive instantiation, not
// inferred DDR coding, is the only reliable way to get real ODDR/IDDR
// behavior from a synthesis tool). Verilator's default lint flags
// rgmii_txd_o/rgmii_tx_ctl_o as MULTIDRIVEN (driven by two different-
// edge always blocks) -- expected and benign here specifically because
// this file is never meant to be synthesized; no lint-* Makefile target
// is wired up for it, same as gth_sfp_wrapper.sv has none for the
// opposite reason (real primitives Verilator doesn't know).
//
// Deliberately simplified relative to the real adapter (exercises the
// encode/decode logic, not real clock-domain-crossing timing):
//   - rgmii_txc_o is a plain combinational copy of gtx_clk (the real
//     adapter's ODDRE1-based clock forwarding has its own insertion
//     delay this doesn't model).
//   - RX capture and the GMII output register are both driven directly
//     off rgmii_rxc_i, with no crossing into the gtx_clk domain -- the
//     real adapter's rtl/common/async_fifo.sv-based CDC (RXC is a
//     genuinely different, recovered clock in real hardware, not an
//     assumption made for simulation convenience -- see that file's
//     header) is not reproduced here. A future integration of this
//     model into a larger switch-level testbench would need that
//     addressed; out of scope for this standalone adapter test.

module rgmii_gmii_sim_model (
  input  logic gtx_clk,
  input  logic gtx_rst_n,

  input  logic idelay_refclk_i, // unused (see header) -- kept for a
                                  // drop-in-identical port list with
                                  // rgmii_gmii_adapter.sv
  input  logic idelay_rst_n_i,

  output logic [3:0] rgmii_txd_o,
  output logic       rgmii_tx_ctl_o,
  output logic       rgmii_txc_o,
  input  logic [3:0] rgmii_rxd_i,
  input  logic        rgmii_rx_ctl_i,
  input  logic        rgmii_rxc_i,

  input  logic [7:0] gmii_txd_i,
  input  logic       gmii_tx_en_i,
  input  logic       gmii_tx_er_i,
  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o,
  input  logic       diag_clk_i,
  input  logic       diag_rst_n_i,
  input  logic       diag_clr_overflow_i,
  input  logic       diag_clr_underrun_i,
  output logic       idelay_rdy_o,
  output logic       rx_elastic_overflow_o,
  output logic       rx_elastic_underrun_o
);

  assign idelay_rdy_o           = 1'b1;
  assign rx_elastic_overflow_o  = 1'b0;
  assign rx_elastic_underrun_o  = 1'b0;

  wire unused_idelay = idelay_refclk_i ^ idelay_rst_n_i; // silence lint, no functional use

  // ============================= TX =====================================

  // Deliberately reads gmii_txd_i/tx_en_i/tx_er_i directly in BOTH edge-
  // triggered blocks below, rather than through one shared staging
  // register updated only on the rising edge: a rise-edge block reading
  // such a register on the SAME edge it updates sees the *old* (pre-
  // update) value (standard, portable NBA same-edge semantics), while
  // the fall-edge block -- a genuinely later event, once that update has
  // settled -- would see the *new* value. That one-cycle skew between a
  // byte's rise and fall halves is exactly what corrupted every frame
  // boundary the first time this was written this way; caught by
  // tracing rise_q/fall_q with $strobe (not $display, which itself
  // raced the same same-edge ambiguity and gave misleading traces).
  // gmii_txd_i et al. only change synchronously with gtx_clk (this
  // project's own driving convention throughout, e.g. drive_frame tasks
  // elsewhere), so they're stable across both edges of one gtx_clk
  // cycle -- safe to read directly, unregistered, in each block.

  assign rgmii_txc_o = gtx_clk;

  always_ff @(posedge gtx_clk or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      rgmii_txd_o    <= '0;
      rgmii_tx_ctl_o <= 1'b0;
    end else begin
      rgmii_txd_o    <= gmii_txd_i[3:0]; // low nibble on the rising edge
      rgmii_tx_ctl_o <= gmii_tx_en_i;    // TX_EN on the rising edge
    end
  end

  always_ff @(negedge gtx_clk or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      rgmii_txd_o    <= '0;
      rgmii_tx_ctl_o <= 1'b0;
    end else begin
      rgmii_txd_o    <= gmii_txd_i[7:4];            // high nibble on the falling edge
      rgmii_tx_ctl_o <= gmii_tx_en_i ^ gmii_tx_er_i; // TX_EN^TX_ER on the falling edge
    end
  end

  // ============================= RX =====================================

  logic [3:0] rx_lo_q;
  logic       rx_ctl_rise_q;

  // Captures the rising-edge (low nibble / EN) half of each byte. Read
  // safely by the falling-edge block below -- that's a genuinely later,
  // already-settled event, not a same-edge race.
  always_ff @(posedge rgmii_rxc_i or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      rx_lo_q       <= '0;
      rx_ctl_rise_q <= 1'b0;
    end else begin
      rx_lo_q       <= rgmii_rxd_i;
      rx_ctl_rise_q <= rgmii_rx_ctl_i;
    end
  end

  // A given byte's falling-edge (high nibble / EN^ER) half only exists
  // once this edge itself occurs -- there's no earlier point where both
  // halves of the SAME byte are simultaneously available. So the combine
  // has to happen HERE, reading rgmii_rxd_i/rgmii_rx_ctl_i fresh (this
  // edge's own primary-input values, never ambiguous) for the high
  // nibble, alongside rx_lo_q/rx_ctl_rise_q (settled from the preceding
  // posedge, strictly earlier and not touched again until the next one --
  // also unambiguous). Combining via a THIRD block on the shared posedge
  // instead (reading rx_lo_q/rx_ctl_rise_q there) was tried first and
  // was wrong: same-edge NBA semantics make that read see the *previous*
  // cycle's rise (correct per the LRM, but a full byte stale relative to
  // the fall this edge just captured) -- it produced a spurious rx_er
  // glitch at every frame start/end boundary, caught via $strobe-based
  // tracing (not $display, which raced the same ambiguity and gave
  // misleading traces) after several loopback-delay red herrings.
  always_ff @(negedge rgmii_rxc_i or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      gmii_rxd_o   <= '0;
      gmii_rx_dv_o <= 1'b0;
      gmii_rx_er_o <= 1'b0;
    end else begin
      gmii_rxd_o   <= {rgmii_rxd_i, rx_lo_q};
      gmii_rx_dv_o <= rx_ctl_rise_q;
      gmii_rx_er_o <= rx_ctl_rise_q ^ rgmii_rx_ctl_i;
    end
  end

endmodule
