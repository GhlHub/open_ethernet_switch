// phy_init_seq.sv
//
// Start-up configuration of one TI DP83867 PHY over Clause 22 MDIO, driving
// open_eth_mdio_master's request interface (see mdio_controller.sv, which
// muxes this in ahead of its AXI4-Lite path). No firmware is required for
// the PHY to be usable.
//
// The register sequence is the one TI's driver in Xilinx's U-Boot
// (drivers/net/phy/dp83867.c, dp83867_config) performs for
// phy-mode = "rgmii-id". Xilinx's KR260 device tree uses delay code 0x4
// (1.25 ns) for its own MAC; this design uses RX 0x7 (2.00 ns, the RGMII
// nominal) and TX 0x6 (1.75 ns), chosen from post-route timing of THIS
// design's forwarded TX clock vs data (kr260_rgmii_io.xdc): 1.25 ns failed
// setup by 0.48 ns, 2.00 ns failed hold by 0.15 ns, 1.75 ns closes both.
// Other values as in the device tree (ti,fifo-depth = 1,
// ti,dp83867-rxctrl-strap-quirk):
//   1. PHYIDR2 (reg 3) must read 0xA23x (DP83867), else FAIL.
//   2. STRAP_STS1 (MMD 0x1F:0x006E) bit 11 -> remembered.
//   3. PHYCR (reg 0x10): FIFO depth [15:14] = FIFO_DEPTH, clear bit 10
//      (force link good); clear bit 11 only if STRAP_STS1 bit 11 was set.
//   4. CFG4 (MMD 0x1F:0x0031) bit 7 cleared (rxctrl strap quirk).
//   5. RGMIICTL (MMD 0x1F:0x0032) bits [1:0] set: enable the PHY's internal
//      TX and RX clock delays.
//   6. RGMIIDCTL (MMD 0x1F:0x0086) = {TX_DELAY, RX_DELAY} (4 bits each,
//      0x7 = 2.00 ns, 0x6 = 1.75 ns; codes from the TI binding header ti-dp83867.h).
// MMD access is the Clause 22 indirect method: REGCR (reg 0x0D) <- 0x001F
// (address function, devad 0x1F), ADDAR (reg 0x0E) <- register address,
// REGCR <- 0x401F (data, no post-increment), ADDAR <- / -> data.
//
// Link polling: the DP83867's INT/PWDN pad is NOT wired to the FPGA on the
// KR260 carrier (schematic sheets 20/21: the net has no other node), so after the
// sequence completes this module reads PHYSTS (reg 0x11) every POLL_CYCLES and
// reports link (bit 10), speed (15:14) and duplex (13) plus a one-cycle
// link_change_o pulse whenever the link bit changes (including going invalid when
// the PHY is reset again). Each poll is one MDIO read (~0.1 ms of a 10 ms period)
// during which active_o holds the master.
//
// Not done here (the driver does them, they are not needed for RGMII-ID
// operation): SW reset (the PHY has just come out of hardware reset) and
// restarting auto-negotiation (it is enabled by default).
//
// WAIT_CYCLES is a settle time after go_i rises, covering the carrier's reset
// sequencer and the PHY's post-reset MDIO-ready time (datasheet 6.7: 195 us
// max); the default (~14 ms at 142.9 MHz) is deliberately far longer.
// Register map checked against the DP83867CS/IS/E datasheet SNLS504G.

module phy_init_seq #(
  parameter logic [4:0] PHY_ADDR    = 5'd2,
  parameter int         WAIT_CYCLES = 2_000_000,
  parameter logic [3:0] RX_DELAY    = 4'h7,
  parameter logic [3:0] TX_DELAY    = 4'h6,
  parameter logic [1:0] FIFO_DEPTH  = 2'd1,
  parameter int         POLL_CYCLES = 1_430_000,
  parameter bit         RXCTRL_STRAP_QUIRK = 1'b1
) (
  input  logic        clk,
  input  logic        rstn,
  input  logic        go_i,        // rising edge starts (or restarts) the sequence

  output logic        m_start_o,
  output logic        m_write_o,
  output logic [4:0]  m_phy_o,
  output logic [4:0]  m_reg_o,
  output logic [15:0] m_wdata_o,
  input  logic        m_busy_i,
  input  logic        m_done_i,
  input  logic        m_error_i,
  input  logic [15:0] m_rdata_i,

  output logic        active_o,    // sequencer owns the MDIO master
  output logic        done_o,      // sequence finished OK (level)
  output logic        fail_o,      // absent/wrong PHY or MDIO error (level)

  output logic        link_o,          // PHYSTS.LINK_STATUS from the last good poll (0 until valid)
  output logic [1:0]  link_speed_o,    // 00 10M, 01 100M, 10 1000M
  output logic        link_full_o,
  output logic        link_valid_o,    // latest poll succeeded
  output logic        link_change_o    // one-cycle pulse when link_o changes
);

  localparam int NSTEPS = 9;

  typedef enum logic [3:0] {S_IDLE, S_WAIT, S_ISSUE, S_RUN, S_NEXT, S_DONE, S_FAIL, S_POLL_WAIT} state_t;
  typedef enum logic [1:0] {K_C22_RD, K_C22_WR, K_MMD_RD, K_MMD_WR} kind_t;

  state_t      state_q;
  logic [3:0]  step_q;
  logic [1:0]  sub_q;
  logic [31:0] wait_q;
  logic        go_q;
  logic        err_q;
  logic        strap11_q;
  logic [15:0] rd_q;

  kind_t       kind;
  logic [15:0] st_reg, st_mask, st_set;
  logic        chk_id, cap_strap;

  always_comb begin
    kind = K_C22_RD; st_reg = '0; st_mask = 16'hFFFF; st_set = '0;
    chk_id = 1'b0; cap_strap = 1'b0;
    case (step_q)
      4'd0: begin kind = K_C22_RD; st_reg = 16'h0003; chk_id = 1'b1; end
      4'd1: begin kind = K_MMD_RD; st_reg = 16'h006E; cap_strap = 1'b1; end
      4'd2: begin kind = K_C22_RD; st_reg = 16'h0010; end
      4'd3: begin
        kind = K_C22_WR; st_reg = 16'h0010;
        st_mask = 16'hC400 | (strap11_q ? 16'h0800 : 16'h0000);
        st_set  = {FIFO_DEPTH, 14'd0};
      end
      4'd4: begin kind = K_MMD_RD; st_reg = 16'h0031; end
      4'd5: begin
        kind = K_MMD_WR; st_reg = 16'h0031;
        st_mask = RXCTRL_STRAP_QUIRK ? 16'h0080 : 16'h0000; st_set = '0;
      end
      4'd6: begin kind = K_MMD_RD; st_reg = 16'h0032; end
      4'd7: begin kind = K_MMD_WR; st_reg = 16'h0032; st_mask = 16'h0003; st_set = 16'h0003; end
      4'd8: begin kind = K_MMD_WR; st_reg = 16'h0086; st_mask = 16'hFFFF; st_set = {8'h00, TX_DELAY, RX_DELAY}; end
      4'd13: begin kind = K_C22_RD; st_reg = 16'h0011; end   // link poll (PHYSTS)
      default: ;
    endcase
  end

  wire is_mmd  = (kind == K_MMD_RD) || (kind == K_MMD_WR);
  wire is_read = (kind == K_C22_RD) || (kind == K_MMD_RD);

  always_comb begin
    m_phy_o   = PHY_ADDR;
    m_reg_o   = '0;
    m_write_o = 1'b1;
    m_wdata_o = '0;
    case (sub_q)
      2'd0: begin m_reg_o = 5'h0D; m_wdata_o = 16'h001F; end
      2'd1: begin m_reg_o = 5'h0E; m_wdata_o = st_reg; end
      2'd2: begin m_reg_o = 5'h0D; m_wdata_o = 16'h401F; end
      default: begin
        m_reg_o   = is_mmd ? 5'h0E : st_reg[4:0];
        m_write_o = !is_read;
        m_wdata_o = (rd_q & ~st_mask) | st_set;
      end
    endcase
  end

  assign m_start_o = (state_q == S_ISSUE);
  assign active_o  = (state_q != S_IDLE) && (state_q != S_DONE) && (state_q != S_FAIL) && (state_q != S_POLL_WAIT);
  assign done_o    = (state_q == S_DONE) || (state_q == S_POLL_WAIT) ||
                     ((state_q == S_ISSUE || state_q == S_RUN) && step_q == 4'd13);
  assign fail_o    = (state_q == S_FAIL);

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q   <= S_IDLE;
      step_q    <= '0;
      sub_q     <= '0;
      wait_q    <= '0;
      go_q      <= 1'b0;
      err_q     <= 1'b0;
      link_o    <= 1'b0; link_speed_o <= '0; link_full_o <= 1'b0; link_valid_o <= 1'b0;
      link_change_o <= 1'b0;
      strap11_q <= 1'b0;
      rd_q      <= '0;
    end else begin
      go_q <= go_i;
      link_change_o <= 1'b0;
      if (m_error_i) err_q <= 1'b1;

      case (state_q)
        S_IDLE, S_DONE, S_FAIL: begin
          if (go_i && !go_q) begin
            state_q <= S_WAIT;
            wait_q  <= WAIT_CYCLES;
            step_q  <= '0;
            err_q   <= 1'b0;
          end
          if (link_valid_o || link_o) begin
            link_valid_o <= 1'b0; link_o <= 1'b0;
            if (link_o) link_change_o <= 1'b1;
          end
        end
        S_POLL_WAIT: begin
          if (!go_i) state_q <= S_IDLE;
          else if (wait_q == 0) begin
            state_q <= S_ISSUE; step_q <= 4'd13; sub_q <= 2'd3;
          end else wait_q <= wait_q - 1'b1;
        end
        S_WAIT: begin
          if (!go_i) state_q <= S_IDLE;
          else if (wait_q == 0) begin
            state_q <= S_ISSUE;
            sub_q   <= is_mmd ? 2'd0 : 2'd3;
          end else wait_q <= wait_q - 1'b1;
        end
        S_ISSUE: begin
          state_q <= S_RUN;
          err_q   <= 1'b0;
        end
        S_RUN: begin
          if (m_done_i) begin
            if (step_q == 4'd13) begin
              // link poll finished: invalidate stale link state on a failed read
              if (!err_q && !m_error_i) begin
                link_valid_o <= 1'b1;
                link_o       <= m_rdata_i[10];
                link_speed_o <= m_rdata_i[15:14];
                link_full_o  <= m_rdata_i[13];
                if (m_rdata_i[10] != link_o) link_change_o <= 1'b1;
              end else begin
                link_valid_o <= 1'b0;
                link_o <= 1'b0;
                if (link_o) link_change_o <= 1'b1;
              end
              state_q <= S_POLL_WAIT;
              wait_q  <= POLL_CYCLES;
            end else if (err_q) state_q <= S_FAIL;
            else if (sub_q != 2'd3) begin
              sub_q   <= sub_q + 1'b1;
              state_q <= S_ISSUE;
            end else begin
              if (is_read) rd_q <= m_rdata_i;
              if (cap_strap) strap11_q <= m_rdata_i[11];
              if (chk_id && m_rdata_i[15:4] != 12'hA23) state_q <= S_FAIL;
              else state_q <= S_NEXT;
            end
          end
        end
        S_NEXT: begin
          if (step_q == NSTEPS - 1) begin state_q <= S_POLL_WAIT; wait_q <= 32'd1000; end
          else begin
            step_q  <= step_q + 1'b1;
            state_q <= S_WAIT;
            wait_q  <= 0;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
