// One PL PHY management endpoint. Register ABI is inherited from mdio_controller.
// Clock/reset belong to the AXI-Lite domain; PHY reset release is asynchronous.
module switch_pl_phy_mdio #(
  parameter logic [4:0] INIT_PHY_ADDR = 5'd2,
  parameter int INIT_WAIT_CYCLES = 2_000_000,
  parameter int INIT_POLL_CYCLES = 1_430_000
) (
  input wire clk,
  input wire rst_n,
  input logic [7:0] s_axi_awaddr,
  input  logic                       s_axi_awvalid,
  output logic                       s_axi_awready,
  input  logic [31:0]                s_axi_wdata,
  input  logic [3:0]                 s_axi_wstrb,
  input  logic                       s_axi_wvalid,
  output logic                       s_axi_wready,
  output logic [1:0]                 s_axi_bresp,
  output logic                       s_axi_bvalid,
  input  logic                       s_axi_bready,
  input  logic [7:0] s_axi_araddr,
  input  logic                       s_axi_arvalid,
  output logic                       s_axi_arready,
  output logic [31:0]                s_axi_rdata,
  output logic [1:0]                 s_axi_rresp,
  output logic                       s_axi_rvalid,
  input  logic                       s_axi_rready,

  input wire phy_reset_released_i,
  output wire init_done_o,
  output wire init_fail_o,
  output wire phy_link_o,
  output wire phy_link_change_o,
  inout wire mdio_io,
  output wire mdc_o
);
  // Preserve the board shell's two-stage reset-release sampling.
  (* ASYNC_REG = "TRUE" *) logic [1:0] init_go_sync;
  always_ff @(posedge clk)
    init_go_sync <= {init_go_sync[0], phy_reset_released_i};

  mdio_controller #(
    .INIT_PHY_ADDR(INIT_PHY_ADDR), .INIT_WAIT_CYCLES(INIT_WAIT_CYCLES),
    .INIT_POLL_CYCLES(INIT_POLL_CYCLES)
  ) u_controller (
    .s_axi_lite_clk(clk), .s_axi_lite_resetn(rst_n),
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
    .init_go_i(init_go_sync[1]), .init_done_o(init_done_o), .init_fail_o(init_fail_o),
    .phy_link_o(phy_link_o), .phy_link_change_o(phy_link_change_o),
    .mdio_io(mdio_io), .mdc_o(mdc_o)
  );
endmodule
