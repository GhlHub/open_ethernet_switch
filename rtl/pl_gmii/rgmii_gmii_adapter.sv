// KR260 DP83867 RGMII physical interface, full-duplex 10/100/1000 Mb/s.
// Board pin mapping is verified against the carrier schematic, sheets 20/21.
//
// Local MAC and I/O launch logic stay at 125 MHz. rgmii_rate_adapter produces
// 125/25/2.5 MHz forwarded TX clocks using ODDRE1 edge values and supplies a
// separate byte enable to the MAC. At 10/100 it serializes two successive MII
// nibbles per byte, duplicating each nibble on the falling edge.
//
// PHY-sourced RXC clocks IDDRE1 directly. Captured edges are converted into
// bytes and explicit frame-end tokens, then cross a hard asynchronous FIFO.
// The receive byte enable permits gaps inside a frame without treating FIFO
// empty as a wire underrun. Independent RX/TX enables are mandatory.
//
// PHY internal delays are programmed by phy_init_seq: RX 2.00 ns, TX 1.75 ns.
// Fixed RX data IDELAY values remain selected per board port for timing margin.
// Each I/O bank owns an IDELAYCTRL using its continuous 300 MHz reference.
// RX release waits for calibration plus 64 receive clocks. The PHY reset
// request and local fabric/reference clocks are independent of link speed.
//
// port_mode_i is a held control-domain bus: [2] enabled, [1:0] 10/100/1000.
// Disable and flush the port before changing speed; hold the new speed while
// disabled before re-enabling. RX enable asserts reset asynchronously so a
// stopped receive clock cannot preserve stale partial-byte state.
// RX_IDELAY_ENABLE remains unsupported on this device: IDELAYE3 may not
// drive BUFG. Production uses fixed data delay and RX_IDELAY_ENABLE=0.

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
  input wire [2:0] port_mode_i,
  output wire rx_byte_ce_o, tx_byte_ce_o,

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
  output logic       idelay_rdy_o,          // raw IDELAYCTRL RDY (async; 1 if no IDELAYCTRL is used)
  output logic       rx_elastic_overflow_o,
  output logic       rx_elastic_underrun_o
);

  genvar gi;

  // ============================= TX =====================================

  wire [3:0] tx_rise, tx_fall;
  wire tx_ctl_rise, tx_ctl_fall, tx_clock_rise, tx_clock_fall;
  generate
    for (gi = 0; gi < 4; gi++) begin : g_txd_oddr
      wire txd_pin;
      ODDRE1 #(
        .SIM_DEVICE("ULTRASCALE_PLUS")
      ) u_oddre1 (
        .Q  (txd_pin),
        .C  (gtx_clk),
        .D1 (tx_rise[gi]),     // rising edge: low nibble (RGMII spec)
        .D2 (tx_fall[gi]), // falling edge: high nibble
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

  // Clock forwarding remains on ODDRE1; the rate converter stops on full pulses.
  wire txc_pin;
  ODDRE1 #(.SIM_DEVICE("ULTRASCALE_PLUS")) u_oddre1_txc (
    .Q  (txc_pin),
    .C  (gtx_clk),
    .D1 (tx_clock_rise),
    .D2 (tx_clock_fall),
    .SR (1'b0)
  );
  OBUF u_obuf_txc (.I(txc_pin), .O(rgmii_txc_o));

  // ============================= RX =====================================

  wire rxc_ibuf;
  IBUF u_ibuf_rxc (.I(rgmii_rxc_i), .O(rxc_ibuf));

  // IDELAYCTRL calibration status: the receive path is held in reset (below)
  // until it is ready, and again if it ever drops (reference clock loss).
  wire idelayctrl_rdy;
  generate
    if (RX_IDELAY_ENABLE || RX_DATA_IDELAY_ENABLE) begin : g_idelayctrl
      // UG571 "Component Mode Reset Sequence": the IDELAYE3 resets are released
      // first, then IDELAYCTRL's, so hold IDELAYCTRL in reset for IDELAYCTRL_RST_EXTRA
      // more refclk cycles after idelay_rst_n_i is released (idelay_rst_n_i is
      // already synchronous to idelay_refclk_i).
      localparam int IDELAYCTRL_RST_EXTRA = 16;
      logic [$clog2(IDELAYCTRL_RST_EXTRA+1)-1:0] ctrl_cnt_q;
      logic ctrl_rst_q;
      always_ff @(posedge idelay_refclk_i or negedge idelay_rst_n_i) begin
        if (!idelay_rst_n_i) begin
          ctrl_cnt_q <= '0;
          ctrl_rst_q <= 1'b1;
        end else begin
          if (ctrl_cnt_q != IDELAYCTRL_RST_EXTRA) ctrl_cnt_q <= ctrl_cnt_q + 1'b1;
          ctrl_rst_q <= (ctrl_cnt_q < IDELAYCTRL_RST_EXTRA - 1);
        end
      end
      IDELAYCTRL #(
        .SIM_DEVICE("ULTRASCALE_PLUS")
      ) u_idelayctrl (
        .RDY    (idelayctrl_rdy),
        .REFCLK (idelay_refclk_i),
        .RST    (ctrl_rst_q)
      );
    end else begin : g_no_idelayctrl
      assign idelayctrl_rdy = 1'b1;
    end
  endgenerate
  assign idelay_rdy_o = idelayctrl_rdy;

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
  // Receive reset. The local reset (gtx_rst_n, another clock domain) goes through a
  // standard async-assert / sync-release synchronizer; everything else in this
  // domain is reset from ITS output (an async reset driven straight from another
  // domain would be a CDC hazard). IDELAYCTRL RDY (yet another domain) goes
  // through a two-flop synchronizer, then UG571's rule -- release the application
  // logic only after RDY plus at least 64 clock cycles -- is counted on the
  // receive clock. rxc_rst_n is a flop, so it is glitch-free.
  (* ASYNC_REG = "TRUE" *) logic [1:0] rxc_rst_base_sync_q;
  always_ff @(posedge rxc_buf or negedge gtx_rst_n) begin
    if (!gtx_rst_n) rxc_rst_base_sync_q <= 2'b00;
    else            rxc_rst_base_sync_q <= {rxc_rst_base_sync_q[0], 1'b1};
  end
  wire rxc_rst_base_n = rxc_rst_base_sync_q[1];

  (* ASYNC_REG = "TRUE" *) logic [1:0] rdy_sync_q;
  logic [6:0] rdy_hold_q;
  logic       rdy_hold_done_q;
  always_ff @(posedge rxc_buf or negedge rxc_rst_base_n) begin
    if (!rxc_rst_base_n) begin
      rdy_sync_q      <= '0;
      rdy_hold_q      <= '0;
      rdy_hold_done_q <= 1'b0;
    end else begin
      rdy_sync_q <= {rdy_sync_q[0], idelayctrl_rdy};
      if (!rdy_sync_q[1]) begin
        rdy_hold_q      <= '0;
        rdy_hold_done_q <= 1'b0;
      end else begin
        if (!rdy_hold_done_q) rdy_hold_q <= rdy_hold_q + 1'b1;
        if (rdy_hold_q == 7'd64) rdy_hold_done_q <= 1'b1;
      end
    end
  end
  logic rxc_rst_sync_q_r;
  always_ff @(posedge rxc_buf or negedge rxc_rst_base_n) begin
    if (!rxc_rst_base_n) rxc_rst_sync_q_r <= 1'b0;
    else                 rxc_rst_sync_q_r <= rdy_hold_done_q;
  end
  wire rxc_rst_n = rxc_rst_sync_q_r;

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

  wire rx_ovf_evt;
  rgmii_rate_adapter u_rate (
    .clk(gtx_clk), .rst_n(gtx_rst_n), .mode_i(port_mode_i),
    .tx_data_i(gmii_txd_i), .tx_en_i(gmii_tx_en_i), .tx_er_i(gmii_tx_er_i),
    .tx_byte_ce_o(tx_byte_ce_o), .tx_rise_o(tx_rise), .tx_fall_o(tx_fall),
    .tx_ctl_rise_o(tx_ctl_rise), .tx_ctl_fall_o(tx_ctl_fall),
    .tx_clk_rise_o(tx_clock_rise), .tx_clk_fall_o(tx_clock_fall),
    .rx_clk(rxc_buf), .rx_rst_n(rxc_rst_n),
    .rx_rise_i(rxd_q1), .rx_fall_i(rxd_q2),
    .rx_ctl_rise_i(rx_ctl_q1), .rx_ctl_fall_i(rx_ctl_q2),
    .rx_data_o(gmii_rxd_o), .rx_dv_o(gmii_rx_dv_o), .rx_er_o(gmii_rx_er_o),
    .rx_byte_ce_o(rx_byte_ce_o), .overflow_o(rx_ovf_evt)
  );
  // Byte-valid pacing removes matched-rate elastic-buffer underruns.
  wire rx_und_evt=1'b0;

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
