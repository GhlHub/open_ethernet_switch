// rgmii_gmii_adapter.sv
//
// Converts between the KR260 carrier's actual RGMII pins (per-port
// Texas Instruments DP83867CSRGZ PHY -- confirmed against the real
// carrier schematic, docs/xtp743/038-05101-01_sck-kr_reva02_SKIT_20211015.pdf,
// sheets 20/21 ("PL GEM2/GEM3 RGMII ETHERNET"); Vivado's own
// kr260_carrier board file claims "M88E1111_BAB1C000" (Marvell) for this
// part, which the schematic shows is simply wrong -- board files can be
// mistaken about component identity even when their pin/net data is
// right, see below) and the GMII port pl_gmii_mac_top.sv already expects
// (gmii_txd/tx_en/tx_er in, gmii_rxd/rx_dv/rx_er out, all on one 125MHz
// "gtx_clk" -- see that file's own header). One instance per PL port.
//
// Every pin/net in constraints/kr260_pl_ethernet.xdc was independently
// re-derived from the schematic (PHY pin -> schematic net name -> SOM240
// connector grid position, sheets 6/7 -> package pin, per
// kr260_som/2.0/part0_pins.xml) and matches the board file exactly --
// only the PHY's identity was wrong, not the connectivity. The PHY's own
// pin name for the RGMII TXC function on this part is "GTX_CLK" (pin 29
// -- also a configuration-strap pin sampled at reset on the DP83867;
// no external strap resistor is populated on this net in the schematic,
// so it presumably relies on the PHY's internal default, unconfirmed
// which mode that selects without the DP83867 datasheet in hand).
//
// RGMII v2.0 encoding (IEEE 802.3-independent RGMII spec, not something
// this project needs to re-derive -- these are the well-known, fixed
// rules): each byte crosses the wire as two nibbles on one clock (TXC/
// RXC) -- the low nibble ([3:0]) on the rising edge, the high nibble
// ([7:4]) on the falling edge. TX_CTL/RX_CTL carry TX_EN/RX_DV on the
// rising edge and TX_EN^TX_ER / RX_DV^RX_ER on the falling edge (so
// TX_ER/RX_ER only has meaning while EN/DV is asserted, per spec).
//
// TX: entirely in the gtx_clk domain (this side's clock, TXC, is
// generated locally and forwarded to the PHY -- no CDC needed).
// ODDRE1 packs each byte into its two nibble-edges; a dedicated ODDRE1
// forwards gtx_clk itself out as TXC, kept free-running (never held in
// reset) so the PHY always sees a clean clock even while the rest of
// this adapter resets.
//
// RX: RXC is the PHY's own recovered receive clock -- a real, physically
// distinct clock domain from gtx_clk (this is the actual hardware
// requirement RGMII imposes, not a simplification -- IDDRE1's capture
// flops must be clocked directly by RXC, buffered through a BUFG, not
// by an unrelated local clock). IDDRE1 captures each pin's rising/
// falling-edge bit (SAME_EDGE_PIPELINED mode, Xilinx's own recommended
// mode for exactly this kind of DDR source-synchronous capture -- see
// UG571 -- so both nibbles land together, aligned to one rxc_buf edge).
// The reconstructed byte+dv+er then crosses into gtx_clk through
// rtl/common/async_fifo.sv (this project's existing, already-proven CDC
// building block, reused here exactly as ps_gem_axis_bridge.sv and
// pl_gmii_mac_top.sv already reuse it for their own ~matched-rate,
// independently-clocked boundaries) -- continuous push/pop every cycle
// on both sides, since RGMII RX has no separate "valid" qualifier beyond
// rx_dv itself and idles just as continuously as it carries frames.
//
// RX clock-skew compensation (RX_IDELAY_ENABLE, default OFF -- see the
// implementation note below; the paragraph that follows describes the
// original clock-delay scheme, kept for RX_IDELAY_ENABLE=1): the
// DP83867 can be strapped for either "RGMII" (needs board/FPGA-side
// delay between RXC and RXD/RX_CTL) or "RGMII-ID" (PHY adds the delay
// internally, no FPGA-side delay wanted) -- the schematic doesn't show
// strap resistor values for this (a GreenPAK-style I2C-configurable
// part elsewhere on the board suggests some strapping may be done in
// software/I2C, not fixed resistors), so which mode is actually active
// remains unconfirmed. This defaults to FPGA-side delay (applied to the
// clock via IDELAYE3, not the 5 data lines -- the simpler, more common
// of the two standard RGMII skew-compensation schemes) and MUST be
// verified/disabled against real hardware before bring-up if the PHY
// turns out already strapped for RGMII-ID (both delaying would double
// the skew, not cancel it).
//
// IMPLEMENTATION FINDING 2 (RX data hold): with the RX clock on a BUFG the clock
// insertion delay exceeds the data path, and the centre-aligned RGMII input
// constraints (kr260_rgmii_io.xdc) showed ~-0.26 ns hold at the IDDRE1s. The
// data/ctl pins therefore go through IDELAYE3 (RX_DATA_IDELAY_PS, needs the
// IDELAYCTRL below); the clock is not delayed.
//
// IMPLEMENTATION FINDING (place_design DRC on the full board build, not
// visible in simulation or isolated synthesis): IDELAYE3's DATAOUT may not
// drive a BUFG ("IDELAYE3 drives invalid load ... may not drive a BUFG*"),
// so the clock-delay scheme above (IBUF -> IDELAYE3 -> BUFG) is illegal on
// this device and RX_IDELAY_ENABLE=1 cannot be implemented as written.
// Fixing it means delaying the data/ctl lines instead (the other standard
// scheme, with the PHY clock edge-aligned), or -- the choice made here --
// having the PHY add the RX delay (RGMII-ID, which is how the KR260
// Linux device tree describes these PHYs), so the FPGA needs none. That
// requires the DP83867's RX internal delay to be enabled (strap or MDIO)
// before real traffic; until it is, RX sampling margin is unverified.
// TX likewise forwards an unshifted clock, relying on the PHY's TX delay.
//
// idelay_refclk_i (200-800MHz-class, IDELAYE3/IDELAYCTRL's own
// reference, per UG571) has no source anywhere yet in this project.
// Per the schematic (sheet 16, "Clock Gen, Reset"), each PL port's own
// 25MHz reference at the FPGA (HPA_CLK0P_CLK/HPB_CLK0P_CLK -- confirmed
// clock-capable ("_GC_") pins, in the same I/O bank as the rest of that
// port's own RGMII pins) is one of four buffered taps (via a 1:4 clock
// buffer, NB3V1104CDTR2G) off a single shared 25MHz oscillator -- the
// OTHER two taps feed the two PHYs' own crystal inputs directly. So this
// pin is phase-related to the same oscillator the PHY itself uses
// internally, not an arbitrary nearby clock, which makes it a
// particularly good MMCM seed for idelay_refclk_i -- but this project
// hasn't defined any clock-generation architecture yet; generating it
// remains a board-integration-level decision, out of scope here.

module rgmii_gmii_adapter #(
  parameter bit RX_DATA_IDELAY_ENABLE = 1'b1, // IDELAYE3 on the 5 RX data/ctl pins (see IMPLEMENTATION FINDING 2)
  parameter int RX_DATA_IDELAY_PS     = 500,
  parameter bit RX_IDELAY_ENABLE     = 1'b0,
  parameter int RX_IDELAY_VALUE_PS   = 700,  // see header -- verify against real hardware;
                                              // IDELAYE3's own legal range for
                                              // DELAY_FORMAT="TIME" on this part is
                                              // 0-1100 (confirmed via Vivado xsim,
                                              // not just UG571 text)
  parameter real IDELAY_REFCLK_MHZ   = 300.0
) (
  input  logic gtx_clk,     // 125 MHz, matches pl_gmii_mac_top.sv's own gtx_clk
  input  logic gtx_rst_n,

  input  logic idelay_refclk_i, // see header; unused if RX_IDELAY_ENABLE=0
  input  logic idelay_rst_n_i,

  // RGMII pins (board-level, -> constraints/kr260_pl_ethernet.xdc)
  output logic [3:0] rgmii_txd_o,
  output logic       rgmii_tx_ctl_o,
  output logic       rgmii_txc_o,
  input  logic [3:0] rgmii_rxd_i,
  input  logic        rgmii_rx_ctl_i,
  input  logic        rgmii_rxc_i,

  // GMII (-> pl_gmii_mac_top.sv's gmii_txd/tx_en/tx_er in, gmii_rxd/
  // rx_dv/rx_er out -- note the direction flip: this module's *input*
  // feeds that module's *output* port and vice versa)
  input  logic [7:0] gmii_txd_i,
  input  logic       gmii_tx_en_i,
  input  logic       gmii_tx_er_i,
  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o,

  // Elastic-buffer diagnostics: sticky flags in the diag_clk_i (CPU/AXI-Lite)
  // domain, set by a lost/truncated receive word, cleared by a one-cycle pulse
  // on the matching clear input. Both should stay 0.
  input  logic       diag_clk_i,
  input  logic       diag_rst_n_i,
  input  logic       diag_clr_overflow_i,
  input  logic       diag_clr_underrun_i,
  output logic       rx_elastic_overflow_o,
  output logic       rx_elastic_underrun_o
);

  genvar gi;

  // ============================= TX =====================================

  logic [7:0] tx_byte_q;
  logic       tx_en_q, tx_er_q;

  always_ff @(posedge gtx_clk or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      tx_byte_q <= '0;
      tx_en_q   <= 1'b0;
      tx_er_q   <= 1'b0;
    end else begin
      tx_byte_q <= gmii_txd_i;
      tx_en_q   <= gmii_tx_en_i;
      tx_er_q   <= gmii_tx_er_i;
    end
  end

  wire tx_ctl_rise = tx_en_q;
  wire tx_ctl_fall = tx_en_q ^ tx_er_q;

  generate
    for (gi = 0; gi < 4; gi++) begin : g_txd_oddr
      wire txd_pin;
      ODDRE1 #(
        .SIM_DEVICE("ULTRASCALE_PLUS")
      ) u_oddre1 (
        .Q  (txd_pin),
        .C  (gtx_clk),
        .D1 (tx_byte_q[gi]),     // rising edge: low nibble (RGMII spec)
        .D2 (tx_byte_q[gi + 4]), // falling edge: high nibble
        .SR (!gtx_rst_n)
      );
      OBUF u_obuf (.I(txd_pin), .O(rgmii_txd_o[gi]));
    end
  endgenerate

  wire tx_ctl_pin;
  ODDRE1 #(.SIM_DEVICE("ULTRASCALE_PLUS")) u_oddre1_ctl (
    .Q  (tx_ctl_pin),
    .C  (gtx_clk),
    .D1 (tx_ctl_rise),
    .D2 (tx_ctl_fall),
    .SR (!gtx_rst_n)
  );
  OBUF u_obuf_ctl (.I(tx_ctl_pin), .O(rgmii_tx_ctl_o));

  // clock-forward: never held in reset (see header)
  wire txc_pin;
  ODDRE1 #(.SIM_DEVICE("ULTRASCALE_PLUS")) u_oddre1_txc (
    .Q  (txc_pin),
    .C  (gtx_clk),
    .D1 (1'b1),
    .D2 (1'b0),
    .SR (1'b0)
  );
  OBUF u_obuf_txc (.I(txc_pin), .O(rgmii_txc_o));

  // ============================= RX =====================================

  wire rxc_ibuf;
  IBUF u_ibuf_rxc (.I(rgmii_rxc_i), .O(rxc_ibuf));

  generate
    if (RX_IDELAY_ENABLE || RX_DATA_IDELAY_ENABLE) begin : g_idelayctrl
      wire idelayctrl_rdy;
      IDELAYCTRL #(
        .SIM_DEVICE("ULTRASCALE_PLUS")
      ) u_idelayctrl (
        .RDY    (idelayctrl_rdy),
        .REFCLK (idelay_refclk_i),
        .RST    (!idelay_rst_n_i)
      );
    end
  endgenerate

  wire rxc_delayed;
  generate
    if (RX_IDELAY_ENABLE) begin : g_rx_idelay
      IDELAYE3 #(
        .DELAY_TYPE      ("FIXED"),
        .DELAY_FORMAT    ("TIME"),
        .DELAY_VALUE     (RX_IDELAY_VALUE_PS),
        .REFCLK_FREQUENCY(IDELAY_REFCLK_MHZ),
        .SIM_DEVICE      ("ULTRASCALE_PLUS"),
        .DELAY_SRC       ("IDATAIN")
      ) u_idelaye3_rxc (
        .DATAOUT     (rxc_delayed),
        .IDATAIN     (rxc_ibuf),
        .CLK         (idelay_refclk_i),
        .CE          (1'b0),
        .INC         (1'b0),
        .LOAD        (1'b0),
        .CNTVALUEIN  (9'd0),
        .CNTVALUEOUT (),
        .RST         (!idelay_rst_n_i),
        .EN_VTC      (1'b1),
        .CASC_IN     (1'b0),
        .CASC_RETURN (1'b0),
        .CASC_OUT    (),
        .DATAIN      (1'b0)
      );
    end else begin : g_rx_no_idelay
      assign rxc_delayed = rxc_ibuf;
    end
  endgenerate

  wire rxc_buf;
  BUFG u_bufg_rxc (.I(rxc_delayed), .O(rxc_buf));
  wire rxc_bufn = ~rxc_buf; // IDDRE1's CB -- local inversion, standard usage

  // small reset synchronizer into the rxc_buf domain, for the CDC FIFO
  // below only (IDDRE1 itself is left free-running -- see header)
  (* ASYNC_REG = "TRUE" *) logic [1:0] rxc_rst_sync_q;
  always_ff @(posedge rxc_buf or negedge gtx_rst_n) begin
    if (!gtx_rst_n) rxc_rst_sync_q <= 2'b00;
    else            rxc_rst_sync_q <= {rxc_rst_sync_q[0], 1'b1};
  end
  wire rxc_rst_n = rxc_rst_sync_q[1];

  wire [3:0] rxd_q1, rxd_q2; // q1=rising(low nibble), q2=falling(high nibble)
  generate
    for (gi = 0; gi < 4; gi++) begin : g_rxd_iddr
      wire rxd_pin, rxd_ibuf;
      IBUF u_ibuf (.I(rgmii_rxd_i[gi]), .O(rxd_pin));
      if (RX_DATA_IDELAY_ENABLE) begin : g_dly
      IDELAYE3 #(.DELAY_TYPE("FIXED"), .DELAY_FORMAT("TIME"), .DELAY_VALUE(RX_DATA_IDELAY_PS),
                   .REFCLK_FREQUENCY(IDELAY_REFCLK_MHZ), .SIM_DEVICE("ULTRASCALE_PLUS"), .DELAY_SRC("IDATAIN")) u_idly (
          .DATAOUT (rxd_ibuf), .IDATAIN (rxd_pin), .CLK (idelay_refclk_i),
          .CE (1'b0), .INC (1'b0), .LOAD (1'b0), .CNTVALUEIN (9'd0), .CNTVALUEOUT (),
          .RST (!idelay_rst_n_i), .EN_VTC (1'b1), .CASC_IN (1'b0), .CASC_RETURN (1'b0),
          .CASC_OUT (), .DATAIN (1'b0));
      end else begin : g_nodly
        assign rxd_ibuf = rxd_pin;
      end
      IDDRE1 #(
        .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED")
      ) u_iddre1 (
        .Q1 (rxd_q1[gi]),
        .Q2 (rxd_q2[gi]),
        .C  (rxc_buf),
        .CB (rxc_bufn),
        .D  (rxd_ibuf),
        .R  (1'b0)
      );
    end
  endgenerate

  wire rx_ctl_pin, rx_ctl_ibuf;
  IBUF u_ibuf_rx_ctl (.I(rgmii_rx_ctl_i), .O(rx_ctl_pin));
  generate
    if (RX_DATA_IDELAY_ENABLE) begin : g_dly_ctl
      IDELAYE3 #(.DELAY_TYPE("FIXED"), .DELAY_FORMAT("TIME"), .DELAY_VALUE(RX_DATA_IDELAY_PS),
                 .REFCLK_FREQUENCY(IDELAY_REFCLK_MHZ), .SIM_DEVICE("ULTRASCALE_PLUS"), .DELAY_SRC("IDATAIN")) u_idly (
        .DATAOUT (rx_ctl_ibuf), .IDATAIN (rx_ctl_pin), .CLK (idelay_refclk_i),
        .CE (1'b0), .INC (1'b0), .LOAD (1'b0), .CNTVALUEIN (9'd0), .CNTVALUEOUT (),
        .RST (!idelay_rst_n_i), .EN_VTC (1'b1), .CASC_IN (1'b0), .CASC_RETURN (1'b0),
        .CASC_OUT (), .DATAIN (1'b0));
    end else begin : g_nodly_ctl
      assign rx_ctl_ibuf = rx_ctl_pin;
    end
  endgenerate
  wire rx_ctl_q1, rx_ctl_q2;
  IDDRE1 #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED")) u_iddre1_ctl (
    .Q1 (rx_ctl_q1),
    .Q2 (rx_ctl_q2),
    .C  (rxc_buf),
    .CB (rxc_bufn),
    .D  (rx_ctl_ibuf),
    .R  (1'b0)
  );

  wire [7:0] rx_byte = {rxd_q2, rxd_q1};
  wire       rx_dv   = rx_ctl_q1;
  wire       rx_er   = rx_ctl_q1 ^ rx_ctl_q2;

  // Elastic buffer (hard FIFO36E2, see rgmii_rx_elastic.sv): absorbs the ppm
  // difference between the PHY's receive clock and gtx_clk in the inter-frame
  // gap only, so frames are never corrupted.
  wire rx_ovf_evt, rx_und_evt;
  rgmii_rx_elastic u_rx_elastic (
    .rxc          (rxc_buf),
    .rxc_rst_n    (rxc_rst_n),
    .in_dv        (rx_dv),
    .in_er        (rx_er),
    .in_data      (rx_byte),
    .gtx_clk      (gtx_clk),
    .gtx_rst_n    (gtx_rst_n),
    .gmii_rxd_o   (gmii_rxd_o),
    .gmii_rx_dv_o (gmii_rx_dv_o),
    .gmii_rx_er_o (gmii_rx_er_o),
    .overflow_evt_o (rx_ovf_evt),
    .underrun_evt_o (rx_und_evt)
  );

  sticky_xdomain u_sticky_ovf (
    .src_clk (rxc_buf),   .src_rst_n (rxc_rst_n), .event_i (rx_ovf_evt),
    .dst_clk (diag_clk_i), .dst_rst_n (diag_rst_n_i), .clear_i (diag_clr_overflow_i),
    .flag_o  (rx_elastic_overflow_o)
  );
  sticky_xdomain u_sticky_und (
    .src_clk (gtx_clk),   .src_rst_n (gtx_rst_n), .event_i (rx_und_evt),
    .dst_clk (diag_clk_i), .dst_rst_n (diag_rst_n_i), .clear_i (diag_clr_underrun_i),
    .flag_o  (rx_elastic_underrun_o)
  );

endmodule
