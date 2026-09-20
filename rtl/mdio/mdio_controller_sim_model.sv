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
  parameter int AXI_ADDR_WIDTH = 8,
  parameter logic [4:0] INIT_PHY_ADDR = 5'd2,
  parameter int INIT_WAIT_CYCLES = 2_000_000,
  parameter int INIT_POLL_CYCLES = 1_430_000
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

  // DP83867 start-up sequencer (phy_init_seq.sv): runs on a rising edge of
  // init_go_i (tie to "PHY reset released"); AXI transactions are held off
  // (STATUS.BUSY reads 1) while it runs.
  input  logic init_go_i,
  output logic init_done_o,
  output logic init_fail_o,
  output logic phy_link_o,          // PHYSTS link bit from the poller (0 until valid)
  output logic phy_link_change_o,   // one-cycle pulse on a change

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

  logic        init_active, seq_start, seq_write;
  logic [1:0]  phy_speed;
  logic        phy_full, phy_valid;
  logic [4:0]  seq_phy, seq_reg;
  logic [15:0] seq_wdata;

  phy_init_seq #(.PHY_ADDR(INIT_PHY_ADDR), .WAIT_CYCLES(INIT_WAIT_CYCLES), .POLL_CYCLES(INIT_POLL_CYCLES)) u_init (
    .clk (s_axi_lite_clk), .rstn (s_axi_lite_resetn), .go_i (init_go_i),
    .m_start_o (seq_start), .m_write_o (seq_write), .m_phy_o (seq_phy),
    .m_reg_o (seq_reg), .m_wdata_o (seq_wdata),
    .m_busy_i (busy), .m_done_i (done), .m_error_i (error), .m_rdata_i (read_data),
    .active_o (init_active), .done_o (init_done_o), .fail_o (init_fail_o),
    .link_o (phy_link_o), .link_speed_o (phy_speed), .link_full_o (phy_full),
    .link_valid_o (phy_valid), .link_change_o (phy_link_change_o)
  );

  open_eth_mdio_master u_master (
    .clk            (s_axi_lite_clk),
    .resetn         (s_axi_lite_resetn),
    .clk_divider    (clk_divider_q),
    .start          (init_active ? seq_start : start_pulse),
    .write_not_read (init_active ? seq_write : write_not_read_q),
    .phy_addr       (init_active ? seq_phy   : phy_addr_q),
    .reg_addr       (init_active ? seq_reg   : reg_addr_q),
    .write_data     (init_active ? seq_wdata : write_data_q),
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

  // A START written while the master is busy with the PHY start-up/poll sequencer
  // is remembered and issued as soon as the master is free (a START written
  // while a CPU transaction is running is still ignored, as documented).
  logic start_pending_q;
  wire  cpu_start_req = write_fire && (aw_hold == 8'h0C) && wstrb_hold[0] && w_hold[0];
  assign start_pulse = (cpu_start_req || start_pending_q) && !busy && !init_active;

  always_ff @(posedge s_axi_lite_clk or negedge s_axi_lite_resetn) begin
    if (!s_axi_lite_resetn) begin
      aw_hold_valid    <= 1'b0;
      w_hold_valid     <= 1'b0;
      s_axi_bvalid     <= 1'b0;
      write_not_read_q <= 1'b0;
      phy_addr_q       <= '0;
      reg_addr_q       <= '0;
      write_data_q     <= '0;
      clk_divider_q    <= 16'd35;
      done_sticky_q    <= 1'b0;
      error_sticky_q   <= 1'b0;
      start_pending_q  <= 1'b0;
    end else begin
      if (start_pulse) start_pending_q <= 1'b0;
      else if (cpu_start_req && (busy || init_active)) start_pending_q <= init_active;
      if (s_axi_awready && s_axi_awvalid) begin
        aw_hold       <= s_axi_awaddr;
        aw_hold_valid <= 1'b1;
      end
      if (s_axi_wready && s_axi_wvalid) begin
        w_hold       <= s_axi_wdata;
        wstrb_hold   <= s_axi_wstrb;
        w_hold_valid <= 1'b1;
      end

      if (done && !init_active)  done_sticky_q  <= 1'b1;
      if (error && !init_active) error_sticky_q <= 1'b1;

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
          8'h10:   s_axi_rdata <= {22'd0, phy_valid, phy_full, phy_speed, phy_link_o, init_fail_o, init_done_o, error_sticky_q, done_sticky_q, busy | init_active};
          8'h14:   s_axi_rdata <= {16'd0, clk_divider_q};
          default: s_axi_rdata <= 32'd0;
        endcase
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end

  assign s_axi_rresp = 2'b00;

endmodule
