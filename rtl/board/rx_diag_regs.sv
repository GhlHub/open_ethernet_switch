// rx_diag_regs.sv
//
// CPU-visible diagnostics: sticky flags for the two PL RGMII receive elastic
// buffers, and status/control of the SFP sideband (sfp_sideband.sv).
// AXI4-Lite slave, 32-bit registers:
//   0x00 STATUS  bit0 PL0 overflow, bit1 PL0 underrun, bit2 PL1 overflow,
//                bit3 PL1 underrun. Sticky; write 1 to a bit to clear it
//                (a write of 0 does nothing). A set flag means a receive word
//                was lost (overflow) or a frame was truncated because the FIFO
//                ran dry (underrun) since the last clear.
//   0x04 SFP_STATUS (read-only; sticky bits cleared by writing 1 to the bit)
//                bit0 MOD_ABS (module absent), bit1 LOS, bit2 TX_FAULT,
//                bit3 TX_DISABLE as driven, bit4 fault lockout,
//                bit5 fault seen (W1C), bit6 module removal seen (W1C),
//                bits15:8 consecutive TX_FAULT count.
//   0x08 SFP_CONTROL  bit0 force TX_DISABLE (laser off; reset 0), bit1 write 1
//                to leave fault lockout (reads 0).
// Flags come from sticky_xdomain (sourced in the RGMII clock domains).

module rx_diag_regs (
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
  output logic [3:0]  clear_o,   // one-cycle pulses

  input  logic [15:0] sfp_status_i,
  output logic        sfp_force_disable_o,
  output logic        sfp_clr_fault_seen_o,
  output logic        sfp_clr_removed_seen_o,
  output logic        sfp_clr_lockout_o
);

  logic [7:0]  aw_hold;
  logic        aw_valid_q, w_valid_q;
  logic [31:0] w_hold;
  logic [3:0]  wstrb_hold;

  assign s_axi_awready = rst_n && !aw_valid_q && !s_axi_bvalid;
  assign s_axi_wready  = rst_n && !w_valid_q  && !s_axi_bvalid;
  wire   write_fire = aw_valid_q && w_valid_q && !s_axi_bvalid;

  assign clear_o = (write_fire && aw_hold == 8'h00 && wstrb_hold[0]) ? w_hold[3:0] : 4'b0;
  wire sfp_st_wr  = write_fire && aw_hold == 8'h04 && wstrb_hold[0];
  wire sfp_ctl_wr = write_fire && aw_hold == 8'h08 && wstrb_hold[0];
  assign sfp_clr_fault_seen_o   = sfp_st_wr && w_hold[5];
  assign sfp_clr_removed_seen_o = sfp_st_wr && w_hold[6];
  assign sfp_clr_lockout_o      = sfp_ctl_wr && w_hold[1];
  logic force_q;
  assign sfp_force_disable_o = force_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) force_q <= 1'b0;
    else if (sfp_ctl_wr) force_q <= w_hold[0];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_valid_q   <= 1'b0;
      w_valid_q    <= 1'b0;
      s_axi_bvalid <= 1'b0;
    end else begin
      if (s_axi_awready && s_axi_awvalid) begin aw_hold <= s_axi_awaddr; aw_valid_q <= 1'b1; end
      if (s_axi_wready && s_axi_wvalid)   begin w_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb; w_valid_q <= 1'b1; end
      if (write_fire) begin
        aw_valid_q   <= 1'b0;
        w_valid_q    <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
  end
  assign s_axi_bresp = 2'b00;

  logic [7:0] ar_hold;
  logic       ar_valid_q;
  assign s_axi_arready = rst_n && !ar_valid_q && !s_axi_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_valid_q   <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
    end else begin
      if (s_axi_arready && s_axi_arvalid) begin ar_hold <= s_axi_araddr; ar_valid_q <= 1'b1; end
      if (ar_valid_q && !s_axi_rvalid) begin
        ar_valid_q   <= 1'b0;
        s_axi_rvalid <= 1'b1;
        case (ar_hold)
          8'h00:   s_axi_rdata <= {28'd0, flags_i};
          8'h04:   s_axi_rdata <= {16'd0, sfp_status_i};
          8'h08:   s_axi_rdata <= {31'd0, force_q};
          default: s_axi_rdata <= 32'd0;
        endcase
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end
  assign s_axi_rresp = 2'b00;

  wire unused_ok = &{1'b0, s_axi_awaddr[0], wstrb_hold[3:1]};
endmodule
