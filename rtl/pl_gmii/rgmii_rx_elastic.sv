// rgmii_rx_elastic.sv
//
// Elastic buffer between the RGMII receive clock (PHY-derived, rxc) and the
// local 125 MHz GMII clock (gtx_clk). The two are nominally equal but come from
// different crystals, so they drift by tens of ppm. A 2048-deep hard FIFO
// (fifo36_async_2kx18) holds a cushion; the two clocks' difference is absorbed
// ONLY in the inter-frame gap, so frame bytes are never dropped or repeated:
//
//   write side (rxc): every cycle pushes {er, dv, data}. If the FIFO holds more
//     than HIGH words, idle cycles (dv=0, er=0) are NOT pushed, but never
//     shortening the pushed idle run below MIN_IDLE.
//   read side (gtx_clk): pops one entry per cycle. Outside a frame it waits
//     (emitting idle) until the FIFO holds at least LOW words, so a frame always
//     starts with a LOW-word cushion and cannot run dry (a frame of N cycles
//     consumes at most N * drift_ppm of it). Inside a frame it never stalls.
//
// In-band RGMII status in the idle data nibble is preserved (idle entries are
// passed through, the held idle data is the last one seen).
//
// Diagnostic events (one-cycle pulses, neither should ever occur; the adapter
// makes them sticky and CPU-clearable): overflow_evt_o (rxc domain: a word
// arrived with the FIFO full and was lost), underrun_evt_o (gtx_clk domain:
// the FIFO ran dry inside a frame; the frame is truncated with dv=0).

module rgmii_rx_elastic #(
  parameter int LOW      = 64,
  parameter int HIGH     = 128,
  parameter int MIN_IDLE = 8
) (
  input  logic       rxc,
  input  logic       rxc_rst_n,     // synchronous to rxc
  input  logic       in_dv,
  input  logic       in_er,
  input  logic [7:0] in_data,

  input  logic       gtx_clk,
  input  logic       gtx_rst_n,
  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o,

  output logic       overflow_evt_o,  // rxc domain pulse
  output logic       underrun_evt_o   // gtx_clk domain pulse
);

  logic        wr_full, rd_empty;
  logic [11:0] wr_count, rd_count;
  logic [17:0] rd_data;
  logic        do_pop;

  // ---- write side ----
  logic [4:0] idle_run_q;      // consecutive idle words pushed
  logic       armed_q;         // FIFO has left its post-reset busy window

  wire in_idle  = !in_dv && !in_er;
  wire drop     = in_idle && (idle_run_q >= 5'(MIN_IDLE)) && (wr_count > 12'(HIGH));
  wire push     = !drop;
  assign overflow_evt_o = push && wr_full && armed_q;

  always_ff @(posedge rxc or negedge rxc_rst_n) begin
    if (!rxc_rst_n) begin
      idle_run_q     <= '0;
      armed_q        <= 1'b0;
    end else begin
      if (!wr_full) armed_q <= 1'b1;
      if (push) begin
        if (in_idle) begin
          if (idle_run_q != 5'd31) idle_run_q <= idle_run_q + 1'b1;
        end else idle_run_q <= '0;
      end
    end
  end

  fifo36_async_2kx18 u_fifo (
    .wr_clk     (rxc),
    .wr_rst_n   (rxc_rst_n),
    .wr_en_i    (push),
    .wr_data_i  ({8'b0, in_er, in_dv, in_data}),
    .wr_full_o  (wr_full),
    .wr_count_o (wr_count),
    .rd_clk     (gtx_clk),
    .rd_en_i    (do_pop),
    .rd_data_o  (rd_data),
    .rd_empty_o (rd_empty),
    .rd_count_o (rd_count)
  );

  // ---- read side ----
  wire in_frame = gmii_rx_dv_o || gmii_rx_er_o;
  assign do_pop = !rd_empty && (in_frame || rd_count >= 12'(LOW));

  always_ff @(posedge gtx_clk or negedge gtx_rst_n) begin
    if (!gtx_rst_n) begin
      gmii_rxd_o   <= '0;
      gmii_rx_dv_o <= 1'b0;
      gmii_rx_er_o <= 1'b0;
    end else begin
      if (do_pop) begin
        gmii_rxd_o   <= rd_data[7:0];
        gmii_rx_dv_o <= rd_data[8];
        gmii_rx_er_o <= rd_data[9];
      end else begin
        gmii_rx_dv_o <= 1'b0;
        gmii_rx_er_o <= 1'b0;
      end
    end
  end

  assign underrun_evt_o = !do_pop && in_frame;

endmodule
