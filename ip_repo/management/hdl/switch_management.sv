// AXI-Lite management and statistics bank routing; firmware ABI unchanged.
module switch_management #(parameter bit STATS_DDR=0, STATS_DEBUG=0,
                      parameter integer STATS_TIMEOUT=4095) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [7:0]  s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [7:0]  s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  input  logic [3:0]  flags_i,   // {pl1_und, pl1_ovf, pl0_und, pl0_ovf}
  input  logic [1:0]  idelay_rdy_i, // {PL1, PL0} IDELAYCTRL ready, already in clk domain
  output logic [3:0]  clear_o,   // one-cycle pulses

  input  logic [15:0] sfp_status_i,
  input  logic [3:0] sfp_pcs_status_i, // synchronized {fault, full, link, sync}
  output logic        sfp_force_disable_o,
  output logic        sfp_clr_fault_seen_o,
  output logic        sfp_clr_removed_seen_o,
  output logic        sfp_clr_lockout_o,

  // link control (axis clk domain; consumed asynchronously by switch_top's
  // port_link_ctrl)
  output logic [5:0]  link_up_o,
  output logic [5:0]  link_flush_tog_o,
  input  logic        link_flush_busy_i,     // fabric domain, synchronized here
  input  logic [1:0]  phy_link_i,        // {PL1, PL0} PHY link, axis domain
  input  logic [5:0]  link_event_set_i,      // axis domain: sets the sticky event bit
  output logic        link_irq_o,

  // per-port control state (see header); axis domain, consumed asynchronously
  // by switch_top's own synchronizers (plain levels for FWD_EN/LEARN_EN, a
  // independent per-port control levels)
  output logic [5:0]  fwd_en_o,
  output logic [5:0]  learn_en_o,

  // CPU RX ingress-port tag FIFO (see header, 0x50): axis domain, same clock
  // as this module -- a plain same-clock pop, not a CDC crossing here (the
  // crossing itself lives inside switch_top.sv, on its own clk/axis_clk).
  input  logic [2:0] cpu_rx_tag_i,
  input  logic       cpu_rx_tag_valid_i,
  output logic       cpu_rx_tag_pop_o,

  output wire [3:0] stats_select,
  output wire [1:0] gem0_req,
  input wire [1:0] gem0_acks,
  input wire [63:0] gem0_values,
  output wire [1:0] gem1_req,
  input wire [1:0] gem1_acks,
  input wire [63:0] gem1_values,
  output wire [0:0] pl0_req,
  input wire [0:0] pl0_acks,
  input wire [31:0] pl0_values,
  output wire [0:0] pl1_req,
  input wire [0:0] pl1_acks,
  input wire [31:0] pl1_values,
  output wire [0:0] sfp_req,
  input wire [0:0] sfp_acks,
  input wire [31:0] sfp_values,
  output wire [5:0] fabric_req,
  input wire [5:0] fabric_acks,
  input wire [191:0] fabric_values
);
  wire stats_request, stats_ack;
  wire [7:0] stats_index;
  wire [31:0] stats_value;
  rx_diag_regs #(.STATS_DDR(STATS_DDR), .STATS_DEBUG(STATS_DEBUG),
                 .STATS_TIMEOUT(STATS_TIMEOUT)) regs (
    .stats_request(stats_request),
    .stats_index(stats_index),
    .stats_ack(stats_ack),
    .stats_value(stats_value),
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .flags_i(flags_i),
    .idelay_rdy_i(idelay_rdy_i),
    .clear_o(clear_o),
    .sfp_status_i(sfp_status_i),
    .sfp_pcs_status_i(sfp_pcs_status_i),
    .sfp_force_disable_o(sfp_force_disable_o),
    .sfp_clr_fault_seen_o(sfp_clr_fault_seen_o),
    .sfp_clr_removed_seen_o(sfp_clr_removed_seen_o),
    .sfp_clr_lockout_o(sfp_clr_lockout_o),
    .link_up_o(link_up_o),
    .link_flush_tog_o(link_flush_tog_o),
    .link_flush_busy_i(link_flush_busy_i),
    .phy_link_i(phy_link_i),
    .link_event_set_i(link_event_set_i),
    .link_irq_o(link_irq_o),
    .fwd_en_o(fwd_en_o),
    .learn_en_o(learn_en_o),
    .cpu_rx_tag_i(cpu_rx_tag_i),
    .cpu_rx_tag_valid_i(cpu_rx_tag_valid_i),
    .cpu_rx_tag_pop_o(cpu_rx_tag_pop_o)
  );
  switch_stats_router router (
    .stats_request(stats_request),
    .stats_index(stats_index),
    .stats_ack(stats_ack),
    .stats_value(stats_value),
    .stats_select(stats_select),
    .gem0_req(gem0_req),
    .gem0_acks(gem0_acks),
    .gem0_values(gem0_values),
    .gem1_req(gem1_req),
    .gem1_acks(gem1_acks),
    .gem1_values(gem1_values),
    .pl0_req(pl0_req),
    .pl0_acks(pl0_acks),
    .pl0_values(pl0_values),
    .pl1_req(pl1_req),
    .pl1_acks(pl1_acks),
    .pl1_values(pl1_values),
    .sfp_req(sfp_req),
    .sfp_acks(sfp_acks),
    .sfp_values(sfp_values),
    .fabric_req(fabric_req),
    .fabric_acks(fabric_acks),
    .fabric_values(fabric_values)
  );
endmodule
