// axis_to_gem_tx_r.sv
//
// AXI4-Stream slave -> PS GEM "Transmit FIFO Interface to PL", for one PS
// GEM instance configured in FIFO Interface mode (UG1085 v2.5, Chapter 34
// "GEM Ethernet", Tables 34-1/34-2; port names match the Vivado-generated
// EMIO wrapper signals emio_enetN_tx_r_*/emio_enetN_dma_tx_* minus the
// "emio_enetN_" prefix -- see gem_rx_w_to_axis.sv for the same note).
//
// This is the direction where the GEM is about to put a frame on the
// wire, and PL is the one that actually holds the frame data -- so from
// the switch's point of view this is an EGRESS sink (a frame the switch
// fabric decided goes out this port leaves the switch here). This module
// is an AXI4-Stream SLAVE whose input plugs into egress_port_rd.sv's
// m_axis_* port (16-bit, same tdata/tkeep/tvalid/tlast convention as
// ingress_port_wr.sv's s_axis_*).
//
// Two clock domains, same rationale as gem_rx_w_to_axis.sv: the GEM side
// (gem_clk) needs its own ~125MHz-class throughput, fixed hardware
// timing; the fabric side (clk) is the switch's 62.5MHz/16-bit
// convention. A small unpacker on the clk side splits each accepted
// 16-bit word into 1 or 2 bytes (tkeep=2'b01 means only the lower byte
// is real, i.e. the trailing byte of an odd-length frame) and pushes
// them one at a time into rtl/common/async_fifo.sv; the GEM-side pull
// logic below is otherwise structurally the same request/response
// design as the original single-clock version, just reading from the
// FIFO's gem_clk read port instead of directly off s_axis_*.
//
// Protocol (UG1085 Ch.34 Table 34-1 + surrounding text): this is a
// request/response PULL, not AXI-Stream valid/ready -- the GEM pulses
// tx_r_rd_i for one cycle to request the next byte, and PL must respond
// with tx_r_valid_o (+ tx_r_data_o/tx_r_sop_o/tx_r_eop_o), which "can be
// returned during the same cycle as the tx_r_rd request" or an arbitrary
// number of cycles later. tx_r_data_rdy_o gates the whole exchange.
//
// tx_r_data_rdy_o here means "the FIFO has at least one byte ready",
// not (as the single-clock version could guarantee) "the whole frame is
// already fully buffered" -- store-and-forward on the fabric side still
// means the rest of a frame follows shortly after its first byte crosses
// into the FIFO, and FIFO_DEPTH provides slack over egress_port_rd.sv's
// brief every-16-bytes RAM-refill bubble, but this is a slightly weaker
// guarantee than before. tx_r_underflow_o is tied low regardless (an
// existing simplification, not new) -- worth reconsidering together if
// real hardware testing ever shows underflow.
//
// Frame content is assumed to already exclude the trailing Ethernet FCS
// -- the GEM's MAC appends its own CRC on transmit, same as it would for
// a normal DMA-sourced frame; tx_r_control_o (no-crc-append) is tied low
// accordingly. tx_r_err_o is tied low: nothing on the egress path here
// marks a frame bad after it has already been buffered (bad frames were
// dropped at ingress). tx_r_flushed_o is tied low, matching tx_r_err_o
// never being asserted (nothing to flush after).
//
// dma_tx_end_tog_i/dma_tx_status_tog_o implement the frame-complete
// acknowledgement handshake from Table 34-2, gem_clk-domain end to end
// (the GEM drives/expects both sides of this exchange in its own clock
// domain): the GEM toggles dma_tx_end_tog_i when a frame completes and
// tx_r_status_i is valid; PL must toggle dma_tx_status_tog_o back to
// acknowledge, which this module does unconditionally on the next cycle
// (tx_r_status_i itself is not otherwise consumed here).

module axis_to_gem_tx_r #(
  parameter int FIFO_DEPTH = 64
) (
  input  logic clk,      // fabric clock (62.5 MHz)
  input  logic rst_n,
  input  logic gem_clk,
  input  logic gem_rst_n,

  // switch egress AXI4-Stream slave, 16-bit (<- egress_port_rd.sv m_axis_*)
  input  logic [15:0] s_axis_tdata,
  input  logic [1:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // GEM TX FIFO interface (gem_clk domain, GEM-driven pull request; PL responds)
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

  // GEM TX FIFO interface status/ack (Table 34-2, gem_clk domain)
  input  logic       dma_tx_end_tog_i,
  output logic       dma_tx_status_tog_o,
  input  logic [3:0] tx_r_status_i
);

  assign tx_r_err_o       = 1'b0;
  assign tx_r_underflow_o = 1'b0;
  assign tx_r_flushed_o   = 1'b0;
  assign tx_r_control_o   = 1'b0;

  localparam int ENTRY_W = 8 + 1; // data + eop

  // ---- fabric side (clk): unpack each accepted 16-bit word into 1 or 2
  // FIFO pushes. async_fifo only accepts one write per cycle, so a full
  // (tkeep=2'b11) word takes 2 fabric cycles to drain in: the lower byte
  // pushes immediately, the upper byte is latched and pushed the
  // following cycle (s_axis_tready held low meanwhile). ----
  typedef enum logic {U_IDLE, U_SECOND} un_state_t;
  un_state_t un_state_q;
  logic [7:0] pending_byte_q;
  logic       pending_eop_q;

  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en, fifo_full;

  always_comb begin
    fifo_wr_en    = 1'b0;
    fifo_wr_data  = '0;
    s_axis_tready = 1'b0;

    unique case (un_state_q)
      U_IDLE: begin
        s_axis_tready = !fifo_full;
        if (s_axis_tvalid && !fifo_full) begin
          fifo_wr_en   = 1'b1;
          fifo_wr_data = {s_axis_tkeep[1] ? 1'b0 : s_axis_tlast, s_axis_tdata[7:0]};
        end
      end
      U_SECOND: begin
        if (!fifo_full) begin
          fifo_wr_en   = 1'b1;
          fifo_wr_data = {pending_eop_q, pending_byte_q};
        end
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      un_state_q <= U_IDLE;
    end else begin
      unique case (un_state_q)
        U_IDLE: begin
          if (s_axis_tvalid && !fifo_full && s_axis_tkeep[1]) begin
            pending_byte_q <= s_axis_tdata[15:8];
            pending_eop_q  <= s_axis_tlast;
            un_state_q     <= U_SECOND;
          end
        end
        U_SECOND: begin
          if (!fifo_full) un_state_q <= U_IDLE;
        end
        default: un_state_q <= U_IDLE;
      endcase
    end
  end

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_rd_en, fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (clk),
    .wr_rst_n  (rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (gem_clk),
    .rd_rst_n  (gem_rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- GEM side (gem_clk): same-cycle pull/response, structurally
  // identical to the original single-clock design, just sourced from the
  // FIFO's read port instead of s_axis_* directly. async_fifo's read
  // side is a combinational peek-before-pop, so this needs no extra
  // registered-read wait state (see the same note in gem_rx_w_to_axis.sv). ----
  wire byte_eop = fifo_rd_data[8];
  wire [7:0] byte_val = fifo_rd_data[7:0];

  assign tx_r_data_rdy_o = !fifo_empty;

  logic sop_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      sop_q <= 1'b1;
    end else if (tx_r_valid_o) begin
      sop_q <= byte_eop;
    end
  end

  assign fifo_rd_en   = tx_r_rd_i && !fifo_empty;
  assign tx_r_valid_o = fifo_rd_en;
  assign tx_r_data_o  = byte_val;
  assign tx_r_sop_o   = tx_r_valid_o && sop_q;
  assign tx_r_eop_o   = tx_r_valid_o && byte_eop;

  // frame-complete ack: unconditionally follow dma_tx_end_tog_i one
  // cycle later (tx_r_status_i isn't otherwise consumed by this module)
  logic dma_tx_end_tog_q;
  always_ff @(posedge gem_clk or negedge gem_rst_n) begin
    if (!gem_rst_n) begin
      dma_tx_end_tog_q   <= 1'b0;
      dma_tx_status_tog_o <= 1'b0;
    end else begin
      dma_tx_end_tog_q <= dma_tx_end_tog_i;
      if (dma_tx_end_tog_i != dma_tx_end_tog_q) dma_tx_status_tog_o <= ~dma_tx_status_tog_o;
    end
  end

endmodule
