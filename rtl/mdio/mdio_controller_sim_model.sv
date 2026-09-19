// mdio_controller_sim_model.sv
//
// Behavioral stand-in for mdio_controller.sv (same port list, same
// register map -- see that file's header), for Icarus/Verilator
// simulation: IOBUF is a real UltraScale+ primitive neither tool can
// simulate. A portable "conditional-Z-assign to an inout port" idiom was
// tried in mdio_controller.sv itself first, hoping it would let one file
// serve both roles, but it didn't reliably synthesize to a real IOBUF
// (see that file's header for the synth_design finding) -- that same
// idiom is exactly right here, though, since this file is never meant
// to be synthesized.
//
// The AXI4-Lite register file and open_eth_mdio_master instantiation
// are identical to mdio_controller.sv; only the pin stage differs.

module mdio_controller_sim_model #(
  parameter int AXI_ADDR_WIDTH = 8
) (
  input  logic s_axi_lite_clk,
  input  logic s_axi_lite_resetn,

  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic                       s_axi_awvalid,
  output logic                       s_axi_awready,
  input  logic [31:0]                s_axi_wdata,
  input  logic [3:0]                 s_axi_wstrb,
  input  logic                       s_axi_wvalid,
  output logic                       s_axi_wready,
  output logic [1:0]                 s_axi_bresp,
  output logic                       s_axi_bvalid,
  input  logic                       s_axi_bready,
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic                       s_axi_arvalid,
  output logic                       s_axi_arready,
  output logic [31:0]                s_axi_rdata,
  output logic [1:0]                 s_axi_rresp,
  output logic                       s_axi_rvalid,
  input  logic                       s_axi_rready,

  inout  wire mdio_io,
  output logic mdc_o
);

  // ---- open_eth_mdio_master + portable tristate pin stage ----

  logic [15:0] clk_divider_q;
  logic        start_pulse;
  logic        write_not_read_q;
  logic [4:0]  phy_addr_q, reg_addr_q;
  logic [15:0] write_data_q;
  logic [15:0] read_data;
  logic        busy, done, error;
  logic        mdio_i, mdio_o, mdio_t;

  open_eth_mdio_master u_master (
    .clk            (s_axi_lite_clk),
    .resetn         (s_axi_lite_resetn),
    .clk_divider    (clk_divider_q),
    .start          (start_pulse),
    .write_not_read (write_not_read_q),
    .phy_addr       (phy_addr_q),
    .reg_addr       (reg_addr_q),
    .write_data     (write_data_q),
    .read_data      (read_data),
    .busy           (busy),
    .done           (done),
    .error          (error),
    .mdc            (mdc_o),
    .mdio_i         (mdio_i),
    .mdio_o         (mdio_o),
    .mdio_t         (mdio_t)
  );

  assign mdio_io = mdio_t ? 1'bz : mdio_o;
  assign mdio_i  = mdio_io;

  // ---- AXI4-Lite register file (identical to mdio_controller.sv) ----

  logic [AXI_ADDR_WIDTH-1:0] aw_hold;
  logic                       aw_hold_valid;
  logic [31:0]                w_hold;
  logic [3:0]                 wstrb_hold;
  logic                       w_hold_valid;

  assign s_axi_awready = s_axi_lite_resetn && !aw_hold_valid && !s_axi_bvalid;
  assign s_axi_wready  = s_axi_lite_resetn && !w_hold_valid  && !s_axi_bvalid;

  wire write_fire = aw_hold_valid && w_hold_valid && !s_axi_bvalid;

  logic done_sticky_q, error_sticky_q;

  assign start_pulse = write_fire && (aw_hold == 8'h0C) && wstrb_hold[0]
                        && w_hold[0] && !busy;

  always_ff @(posedge s_axi_lite_clk or negedge s_axi_lite_resetn) begin
    if (!s_axi_lite_resetn) begin
      aw_hold_valid    <= 1'b0;
      w_hold_valid     <= 1'b0;
      s_axi_bvalid     <= 1'b0;
      write_not_read_q <= 1'b0;
      phy_addr_q       <= '0;
      reg_addr_q       <= '0;
      write_data_q     <= '0;
      clk_divider_q    <= 16'd100;
      done_sticky_q    <= 1'b0;
      error_sticky_q   <= 1'b0;
    end else begin
      if (s_axi_awready && s_axi_awvalid) begin
        aw_hold       <= s_axi_awaddr;
        aw_hold_valid <= 1'b1;
      end
      if (s_axi_wready && s_axi_wvalid) begin
        w_hold       <= s_axi_wdata;
        wstrb_hold   <= s_axi_wstrb;
        w_hold_valid <= 1'b1;
      end

      if (done)  done_sticky_q  <= 1'b1;
      if (error) error_sticky_q <= 1'b1;

      if (write_fire) begin
        aw_hold_valid <= 1'b0;
        w_hold_valid  <= 1'b0;
        s_axi_bvalid  <= 1'b1;
        case (aw_hold)
          8'h00: begin
            if (wstrb_hold[0]) phy_addr_q       <= w_hold[4:0];
            if (wstrb_hold[1]) reg_addr_q       <= w_hold[12:8];
            if (wstrb_hold[2]) write_not_read_q <= w_hold[16];
          end
          8'h04: begin
            if (wstrb_hold[0]) write_data_q[7:0]  <= w_hold[7:0];
            if (wstrb_hold[1]) write_data_q[15:8] <= w_hold[15:8];
          end
          8'h10: begin
            if (wstrb_hold[0] && w_hold[1]) done_sticky_q  <= 1'b0;
            if (wstrb_hold[0] && w_hold[2]) error_sticky_q <= 1'b0;
          end
          8'h14: begin
            if (wstrb_hold[0]) clk_divider_q[7:0]  <= w_hold[7:0];
            if (wstrb_hold[1]) clk_divider_q[15:8] <= w_hold[15:8];
          end
          default: ;
        endcase
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
  end

  assign s_axi_bresp = 2'b00;

  logic [AXI_ADDR_WIDTH-1:0] ar_hold;
  logic                       ar_hold_valid;

  assign s_axi_arready = s_axi_lite_resetn && !ar_hold_valid && !s_axi_rvalid;

  always_ff @(posedge s_axi_lite_clk or negedge s_axi_lite_resetn) begin
    if (!s_axi_lite_resetn) begin
      ar_hold_valid <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= '0;
    end else begin
      if (s_axi_arready && s_axi_arvalid) begin
        ar_hold       <= s_axi_araddr;
        ar_hold_valid <= 1'b1;
      end
      if (ar_hold_valid && !s_axi_rvalid) begin
        ar_hold_valid <= 1'b0;
        s_axi_rvalid  <= 1'b1;
        case (ar_hold)
          8'h00:   s_axi_rdata <= {15'd0, write_not_read_q, 3'd0, reg_addr_q, 3'd0, phy_addr_q};
          8'h04:   s_axi_rdata <= {16'd0, write_data_q};
          8'h08:   s_axi_rdata <= {16'd0, read_data};
          8'h0C:   s_axi_rdata <= 32'd0;
          8'h10:   s_axi_rdata <= {29'd0, error_sticky_q, done_sticky_q, busy};
          8'h14:   s_axi_rdata <= {16'd0, clk_divider_q};
          default: s_axi_rdata <= 32'd0;
        endcase
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end

  assign s_axi_rresp = 2'b00;

endmodule
