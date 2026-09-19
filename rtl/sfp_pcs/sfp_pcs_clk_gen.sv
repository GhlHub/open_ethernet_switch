// sfp_pcs_clk_gen.sv
//
// Generates the SFP PCS's two phase-related clocks from the GTH
// transceiver's 62.5 MHz TXUSRCLK2 (gth_sfp_wrapper.sv's gth_clk_o): the
// 125 MHz GMII/codec clock (gtx_clk_o) and a 62.5 MHz clock (gth_clk_o,
// used for the PCS's GTH-parallel-interface side) -- both from one MMCM
// VCO, so sfp_1000base_x_pcs.sv's fixed 2:1 gearbox relationship holds by
// construction rather than by two unrelated oscillators. See
// rtl/sfp_pcs/ip/sfp_pcs_clk_gen_ip.xci (Clocking Wizard, 62.5 MHz in,
// VCO 1187.5 MHz: 125 MHz via /9.5, 62.5 MHz via /19).
//
// The phase alignment between the MMCM's 62.5 MHz output and the GT's own
// TXUSRCLK2/RXUSRCLK2 is not proven by RTL -- it must be confirmed by
// static timing after implementation (see sfp_1000base_x_pcs.sv's header
// for the same class of caveat).

module sfp_pcs_clk_gen (
  input  logic gth_clk_i,      // 62.5 MHz, gth_sfp_wrapper.sv's gth_clk_o
  input  logic gth_rst_n_i,    // gth_sfp_wrapper.sv's gth_rst_n_o

  output logic gtx_clk_o,      // 125 MHz
  output logic gtx_rst_n_o,    // synchronized to gtx_clk_o
  output logic gth_clk_o,      // 62.5 MHz, phase-related to gtx_clk_o
  output logic gth_rst_n_o,    // synchronized to gth_clk_o
  output logic locked_o
);

  logic locked;
  assign locked_o = locked;

  sfp_pcs_clk_gen_ip u_mmcm (
    .clk_in1  (gth_clk_i),
    .resetn   (gth_rst_n_i),
    .clk_out1 (gtx_clk_o),
    .clk_out2 (gth_clk_o),
    .locked   (locked)
  );

  rst_sync u_gtx_rst (.clk(gtx_clk_o), .arst_n_i(locked), .rst_n_o(gtx_rst_n_o));
  rst_sync u_gth_rst (.clk(gth_clk_o), .arst_n_i(locked), .rst_n_o(gth_rst_n_o));

endmodule
