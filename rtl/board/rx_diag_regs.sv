// rx_diag_regs.sv
//
// CPU-visible diagnostics: sticky flags for the two PL RGMII receive elastic
// buffers, and status/control of the SFP sideband (sfp_sideband.sv).
// AXI4-Lite slave, 32-bit registers:
//   0x00 STATUS  bit0 PL0 overflow, bit1 PL0 underrun, bit2 PL1 overflow,
//                bit3 PL1 underrun. Sticky; write 1 to a bit to clear it
//                (a write of 0 does nothing); bits 5:4 are live read-only IDELAYCTRL
//                ready for PL1/PL0 (1 = calibrated; receive is held in reset while 0).
//                A set flag means a receive word
//                was lost (overflow) or a frame was truncated because the FIFO
//                ran dry (underrun) since the last clear.
//   0x04 SFP_STATUS (read-only; sticky bits cleared by writing 1 to the bit)
//                bit0 MOD_ABS (module absent), bit1 LOS, bit2 TX_FAULT,
//                bit3 TX_DISABLE as driven, bit4 fault lockout,
//                bit5 fault seen (W1C), bit6 module removal seen (W1C),
//                bits15:8 consecutive TX_FAULT count.
//   0x08 SFP_CONTROL  bit0 force TX_DISABLE (laser off; reset 0), bit1 write 1
//                to leave fault lockout (reads 0).
//   0x0C LINK_SET     write 1 to bit p: mark port p link-up (write-1-to-set, so
//                the CPU never read-modify-writes the link state). p: 0 PS GEM0,
//                1 PS GEM1, 2 PL0, 3 PL1, 4 SFP, 5 CPU. Reads 0.
//   0x10 LINK_CLR     write 1 to bit p: mark port p link-down. The switch then
//                stops queueing frames to p, drains p's queued frames (releasing
//                their buffers) and expires p's learned MAC entries. Also acts
//                when the port was already down. Reads 0.
//   0x14 LINK_STATUS  read-only: bits5:0 stored link state (reset: only the CPU
//                port, bit 5, is up), bit8 = a link-down flush is still running
//                in the switch, bits11:10 = PL1/PL0 PHY link (from the MDIO
//                PHYSTS poll, see phy_init_seq.sv).
//   0x18 LINK_EVENT   sticky, write 1 to clear: bit0 PL0 PHY link changed, bit1 PL1
//                PHY link changed (the PHY's INT pin is not wired to the FPGA, so
//                a hardware poller reads PHYSTS every ~10 ms and raises this on a
//                link change; read the MDIO STATUS/PHYSTS for the new state), bit2 SFP
//                link (autonegotiation) changed, bit3 SFP module inserted/removed,
//                bit4 SFP LOS changed, bit5 SFP TX_FAULT seen.
//   0x1C LINK_EVENT_EN  bit p enables LINK_EVENT bit p to raise link_irq_o
//                (level: high while any enabled event bit is set).
// (The PS GEM0/GEM1 PHYs are not covered: their link is the PS's own concern.)
// Flags come from sticky_xdomain (sourced in the RGMII clock domains).

//   0x20 PCS_STATUS read-only {bit3 remote fault, bit2 full duplex,
//                         bit1 negotiation link, bit0 PCS sync}.
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
  output logic        link_irq_o
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

  wire link_set_wr = write_fire && aw_hold == 8'h0C && wstrb_hold[0];
  wire link_clr_wr = write_fire && aw_hold == 8'h10 && wstrb_hold[0];
  wire evt_clr_wr  = write_fire && aw_hold == 8'h18 && wstrb_hold[0];
  wire evt_en_wr   = write_fire && aw_hold == 8'h1C && wstrb_hold[0];
  logic [5:0] event_q, event_en_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] flush_busy_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      link_up_o        <= 6'b100000;
      link_flush_tog_o <= '0;
      event_q          <= '0;
      event_en_q       <= '0;
      flush_busy_s     <= '0;
    end else begin
      flush_busy_s <= {flush_busy_s[0], link_flush_busy_i};
      if (link_set_wr) link_up_o <= link_up_o | w_hold[5:0];
      if (link_clr_wr) begin
        link_up_o        <= link_up_o & ~w_hold[5:0];
        link_flush_tog_o <= link_flush_tog_o ^ w_hold[5:0];
      end
      // set has priority over a same-cycle clear
      event_q <= (event_q & ~(evt_clr_wr ? w_hold[5:0] : 6'b0)) | link_event_set_i;
      if (evt_en_wr) event_en_q <= w_hold[5:0];
    end
  end
  assign link_irq_o = |(event_q & event_en_q);
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
          8'h00:   s_axi_rdata <= {26'd0, idelay_rdy_i, flags_i};
          8'h04:   s_axi_rdata <= {16'd0, sfp_status_i};
          8'h08:   s_axi_rdata <= {31'd0, force_q};
          8'h14:   s_axi_rdata <= {20'd0, phy_link_i, 1'b0, flush_busy_s[1], 2'b00, link_up_o};
          8'h18:   s_axi_rdata <= {26'd0, event_q};
          8'h1C:   s_axi_rdata <= {26'd0, event_en_q};
          8'h20:   s_axi_rdata <= {28'd0, sfp_pcs_status_i};
          default: s_axi_rdata <= 32'd0;
        endcase
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end
  assign s_axi_rresp = 2'b00;

  wire unused_ok = &{1'b0, s_axi_awaddr[0], wstrb_hold[3:1]};
endmodule
