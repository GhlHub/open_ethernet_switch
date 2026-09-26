// mac_rxd_to_switch_ingress.sv
//
// open_eth_mac_1g_switch's m_axis_rxd (32-bit AXI4-Stream, its own
// axis_clk domain -- 150MHz per that core's README, fixed by its
// internal packet buffer/descriptor logic, not reclockable) -> this
// switch's ingress AXI4-Stream convention (16-bit, clk domain, 125MHz).
// Two clock domains. WORD-WIDE datapath (a byte-serial version capped each
// port at 0.8 Gbit/s, below the wire rate): an axis_clk-side splitter turns
// each accepted 32-bit/tkeep beat into one or two 16-bit words
// {eop, upper-byte-valid, data16}, pushed one per cycle into
// rtl/common/async_fifo.sv; the clk side simply presents the FIFO head as the
// 16-bit AXI4-Stream, one word per cycle. Sustained throughput is one word
// per cycle on both sides: 2.0 Gbit/s on the fabric side at 125MHz, 2.3 Gbit/s
// on the MAC side at 142.86MHz.
//
// m_axis_tuser (the switch ingress bad-frame flag) is tied permanently
// low: open_eth_mac_1g_switch already does full internal store-and-
// forward validation (destination-match -- forced-accept in the switch
// fork, CRC, length range, GMII rx_er) before a frame's descriptor is
// even created, so nothing that fails those checks ever reaches
// m_axis_rxd in the first place. There is no tuser/error signal on this
// MAC's rxd channel at all -- frame status instead rides on the
// separate m_axis_rxs channel, which this module does not consume (see
// the top-level wrapper for that channel's simple always-drain tie-off).
//
// tkeep on m_axis_rxd_i is assumed AXI4-Stream-standard: only ever
// non-1111 on the tlast beat, and contiguous valid bytes from bit 0.

module mac_rxd_to_switch_ingress #(
  parameter int FIFO_DEPTH = 256   // 16-bit words
) (
  input  logic axis_clk,   // MAC's AXI4-Stream clock (its own required rate)
  input  logic axis_rst_n,
  input  logic clk,        // fabric clock (125 MHz)
  input  logic rst_n,

  // open_eth_mac_1g_switch's m_axis_rxd, axis_clk domain
  input  logic [31:0] m_axis_rxd_tdata_i,
  input  logic [3:0]  m_axis_rxd_tkeep_i,
  input  logic        m_axis_rxd_tlast_i,
  input  logic        m_axis_rxd_tvalid_i,
  output logic        m_axis_rxd_tready_o,

  // switch ingress AXI4-Stream master, 16-bit, clk domain
  // (-> ingress_port_wr.sv s_axis_*)
  output logic [15:0] s_axis_tdata_o,
  output logic [1:0]  s_axis_tkeep_o,
  output logic         s_axis_tvalid_o,
  output logic         s_axis_tlast_o,
  output logic         s_axis_tuser_o,
  input  logic         s_axis_tready_i
);

  assign s_axis_tuser_o = 1'b0; // see header note: nothing bad ever reaches m_axis_rxd

  localparam int ENTRY_W = 16 + 1 + 1; // data16, upper byte valid, eop

  // ---- axis_clk side: split a 32-bit beat into 1 or 2 words ----
  // tkeep is contiguous from bit 0 (AXI4-Stream standard: only the tlast
  // beat is partial). A second word is needed iff byte 2 is valid.
  wire needs_second = m_axis_rxd_tkeep_i[2];
  wire [ENTRY_W-1:0] word0 = {m_axis_rxd_tlast_i && !needs_second, m_axis_rxd_tkeep_i[1], m_axis_rxd_tdata_i[15:0]};
  wire [ENTRY_W-1:0] word1 = {m_axis_rxd_tlast_i, m_axis_rxd_tkeep_i[3], m_axis_rxd_tdata_i[31:16]};

  logic                pend_v_q;   // the beat's second word is waiting to be pushed
  logic [ENTRY_W-1:0]  pend_q;
  logic                fifo_wr_en, fifo_full;
  logic [ENTRY_W-1:0]  fifo_wr_data;

  // one word per cycle: a beat's second word takes the next cycle, during which
  // the MAC is held off (tready low); single-word beats are accepted every cycle
  assign m_axis_rxd_tready_o = !pend_v_q && !fifo_full;
  wire   accept = m_axis_rxd_tvalid_i && m_axis_rxd_tready_o;

  always_comb begin
    fifo_wr_en   = 1'b0;
    fifo_wr_data = '0;
    if (pend_v_q) begin
      fifo_wr_en   = !fifo_full;
      fifo_wr_data = pend_q;
    end else if (accept) begin
      fifo_wr_en   = 1'b1;
      fifo_wr_data = word0;
    end
  end

  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
      pend_v_q <= 1'b0;
    end else begin
      if (pend_v_q) begin
        if (!fifo_full) pend_v_q <= 1'b0;
      end else if (accept && needs_second) begin
        pend_v_q <= 1'b1;
        pend_q   <= word1;
      end
    end
  end

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (axis_clk),
    .wr_rst_n  (axis_rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (clk),
    .rd_rst_n  (rst_n),
    .rd_en_i   (s_axis_tvalid_o && s_axis_tready_i),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- clk side: the FIFO head IS the stream (first-word-fall-through) ----
  assign s_axis_tvalid_o = !fifo_empty;
  assign s_axis_tdata_o  = fifo_rd_data[15:0];
  assign s_axis_tkeep_o  = {fifo_rd_data[16], 1'b1};
  assign s_axis_tlast_o  = fifo_rd_data[17];

endmodule
