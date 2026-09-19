// ps_gem_axis_bridge.sv
//
// Wraps both directions of the GEM FIFO Interface <-> AXI4-Stream shim
// for one PS GEM instance (GEM0 or GEM1 on KR260's 2 PS Ethernet ports).
// See gem_rx_w_to_axis.sv (switch ingress, GEM RX push) and
// axis_to_gem_tx_r.sv (switch egress, GEM TX pull) for the per-direction
// protocol notes/caveats, both sourced from UG1085 Chapter 34.
//
// Clock domains: gem_rx_clk/gem_tx_clk (with resets) for the GEM-facing side (its own
// required rate, ~125MHz-class, to sustain full gigabit at 8-bit width --
// fixed hardware timing, can't be reclocked) and clk/rst_n for the
// fabric-facing side (the switch's 62.5MHz/16-bit convention). Each half
// below carries its own async_fifo-based CDC; see those two modules for
// the actual crossing logic.

module ps_gem_axis_bridge (
  input  logic clk,      // fabric clock (62.5 MHz)
  input  logic rst_n,
  // The PS gives the GEM FIFO interface SEPARATE receive and transmit
  // clocks (fmio_gemN_fifo_rx/tx_clk_to_pl_bufg); the RX-push side and the
  // TX-pull side each run on their own. (An earlier revision had one
  // gem_clk for both, which put the PS's RX signals in the wrong domain --
  // the board build's CDC report flagged it: gem RX clk -> gem TX clk.)
  input  logic gem_rx_clk,
  input  logic gem_rx_rst_n,
  input  logic gem_tx_clk,
  input  logic gem_tx_rst_n,

  // GEM RX FIFO (gem_rx_clk domain; GEM push -> switch ingress)
  input  logic [7:0]  rx_w_data_i,
  input  logic        rx_w_wr_i,
  input  logic        rx_w_sop_i,
  input  logic        rx_w_eop_i,
  input  logic        rx_w_err_i,
  input  logic        rx_w_flush_i,
  input  logic [44:0] rx_w_status_i,
  output logic        rx_w_overflow_o,

  // switch ingress AXI4-Stream master, 16-bit, clk domain
  // (-> ingress_port_wr.sv s_axis_*)
  output logic [15:0] m_axis_tdata,
  output logic [1:0]  m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,
  input  logic         m_axis_tready,
  output logic [44:0] rx_w_status_o,

  // switch egress AXI4-Stream slave, 16-bit, clk domain
  // (<- egress_port_rd.sv m_axis_*)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // GEM TX FIFO (gem_tx_clk domain; switch egress -> GEM pull)
  input  logic       tx_r_rd_i,
  output logic       tx_r_data_rdy_o,
  output logic       tx_r_valid_o,
  output logic [7:0] tx_r_data_o,
  output logic       tx_r_sop_o,
  output logic       tx_r_eop_o,
  output logic       tx_r_err_o,
  output logic       tx_r_underflow_o,
  output logic       tx_r_flushed_o,
  output logic       tx_r_control_o,
  input  logic       dma_tx_end_tog_i,
  output logic       dma_tx_status_tog_o,
  input  logic [3:0] tx_r_status_i
);

  gem_rx_w_to_axis u_rx (
    .gem_clk         (gem_rx_clk),
    .gem_rst_n       (gem_rx_rst_n),
    .clk             (clk),
    .rst_n           (rst_n),
    .rx_w_data_i     (rx_w_data_i),
    .rx_w_wr_i       (rx_w_wr_i),
    .rx_w_sop_i      (rx_w_sop_i),
    .rx_w_eop_i      (rx_w_eop_i),
    .rx_w_err_i      (rx_w_err_i),
    .rx_w_flush_i    (rx_w_flush_i),
    .rx_w_status_i   (rx_w_status_i),
    .rx_w_overflow_o (rx_w_overflow_o),
    .m_axis_tdata    (m_axis_tdata),
    .m_axis_tkeep    (m_axis_tkeep),
    .m_axis_tvalid   (m_axis_tvalid),
    .m_axis_tlast    (m_axis_tlast),
    .m_axis_tuser    (m_axis_tuser),
    .m_axis_tready   (m_axis_tready),
    .rx_w_status_o   (rx_w_status_o)
  );

  axis_to_gem_tx_r u_tx (
    .clk                 (clk),
    .rst_n               (rst_n),
    .gem_clk             (gem_tx_clk),
    .gem_rst_n           (gem_tx_rst_n),
    .s_axis_tdata        (s_axis_tdata),
    .s_axis_tkeep        (s_axis_tkeep),
    .s_axis_tvalid       (s_axis_tvalid),
    .s_axis_tlast        (s_axis_tlast),
    .s_axis_tready       (s_axis_tready),
    .tx_r_rd_i           (tx_r_rd_i),
    .tx_r_data_rdy_o     (tx_r_data_rdy_o),
    .tx_r_valid_o        (tx_r_valid_o),
    .tx_r_data_o         (tx_r_data_o),
    .tx_r_sop_o          (tx_r_sop_o),
    .tx_r_eop_o          (tx_r_eop_o),
    .tx_r_err_o          (tx_r_err_o),
    .tx_r_underflow_o    (tx_r_underflow_o),
    .tx_r_flushed_o      (tx_r_flushed_o),
    .tx_r_control_o      (tx_r_control_o),
    .dma_tx_end_tog_i    (dma_tx_end_tog_i),
    .dma_tx_status_tog_o (dma_tx_status_tog_o),
    .tx_r_status_i       (tx_r_status_i)
  );

endmodule
