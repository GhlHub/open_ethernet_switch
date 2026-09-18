// mac_rxd_to_switch_ingress.sv
//
// open_eth_mac_1g_switch's m_axis_rxd (32-bit AXI4-Stream, its own
// axis_clk domain -- 150MHz per that core's README, fixed by its
// internal packet buffer/descriptor logic, not reclockable) -> this
// switch's ingress AXI4-Stream convention (16-bit, clk domain, 62.5MHz).
// Two clock domains, same rationale/pattern as rtl/ps_eth/
// gem_rx_w_to_axis.sv: an axis_clk-side unpacker decomposes each
// accepted 32-bit/tkeep beat into up to 4 individual bytes, pushed one
// per cycle into rtl/common/async_fifo.sv; a clk-side packer (identical
// in spirit to gem_rx_w_to_axis.sv's, just without an err bit -- see
// below) recombines pairs of bytes into 16-bit/tkeep words.
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
  parameter int FIFO_DEPTH = 128
) (
  input  logic axis_clk,   // MAC's AXI4-Stream clock (its own required rate)
  input  logic axis_rst_n,
  input  logic clk,        // fabric clock (62.5 MHz)
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

  localparam int ENTRY_W = 8 + 1; // data + eop

  // ---- axis_clk side: latch one accepted 32-bit beat, drain its 1-4
  // valid bytes into the async FIFO one per cycle ----
  logic [31:0] beat_data_q;
  logic [2:0]  valid_bytes_q; // 1..4
  logic        beat_last_q;
  logic [1:0]  byte_idx_q;    // 0..valid_bytes_q-1, next lane to push
  logic        draining_q;

  wire [2:0] valid_bytes_next = {2'd0, m_axis_rxd_tkeep_i[0]} + {2'd0, m_axis_rxd_tkeep_i[1]} +
                                 {2'd0, m_axis_rxd_tkeep_i[2]} + {2'd0, m_axis_rxd_tkeep_i[3]};

  assign m_axis_rxd_tready_o = !draining_q;

  logic [7:0] cur_byte;
  always_comb begin
    unique case (byte_idx_q)
      2'd0:    cur_byte = beat_data_q[7:0];
      2'd1:    cur_byte = beat_data_q[15:8];
      2'd2:    cur_byte = beat_data_q[23:16];
      default: cur_byte = beat_data_q[31:24];
    endcase
  end

  logic [ENTRY_W-1:0] fifo_wr_data;
  logic                fifo_wr_en, fifo_full;

  // subtract in the full 3-bit width first (valid_bytes_q ranges 1..4),
  // then truncate to 2 bits for the compare -- doing it the other way
  // round (truncate then subtract) breaks the valid_bytes_q==4 case:
  // 4[1:0]=0, 0-1 wraps to 3'b11 3, matching nothing.
  wire [2:0] valid_bytes_m1 = valid_bytes_q - 3'd1;
  wire cur_is_last_byte = (byte_idx_q == valid_bytes_m1[1:0]);

  assign fifo_wr_en   = draining_q && !fifo_full;
  assign fifo_wr_data = {beat_last_q && cur_is_last_byte, cur_byte};

  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
      draining_q <= 1'b0;
      byte_idx_q <= '0;
    end else if (!draining_q) begin
      if (m_axis_rxd_tvalid_i) begin
        beat_data_q   <= m_axis_rxd_tdata_i;
        valid_bytes_q <= valid_bytes_next;
        beat_last_q   <= m_axis_rxd_tlast_i;
        byte_idx_q    <= '0;
        draining_q    <= 1'b1;
      end
    end else begin
      if (!fifo_full) begin
        if (cur_is_last_byte) draining_q <= 1'b0;
        else                  byte_idx_q <= byte_idx_q + 1'b1;
      end
    end
  end

  logic [ENTRY_W-1:0] fifo_rd_data;
  logic                fifo_rd_en, fifo_empty;

  async_fifo #(.WIDTH(ENTRY_W), .DEPTH(FIFO_DEPTH)) u_fifo (
    .wr_clk    (axis_clk),
    .wr_rst_n  (axis_rst_n),
    .wr_en_i   (fifo_wr_en),
    .wr_data_i (fifo_wr_data),
    .full_o    (fifo_full),
    .rd_clk    (clk),
    .rd_rst_n  (rst_n),
    .rd_en_i   (fifo_rd_en),
    .rd_data_o (fifo_rd_data),
    .empty_o   (fifo_empty)
  );

  // ---- clk side: pack pairs of popped bytes into 16-bit words. Same
  // structure as gem_rx_w_to_axis.sv's packer (see that file for the
  // detailed reasoning), minus the err bit -- async_fifo's read side is
  // a combinational peek-before-pop, no extra registered-read wait
  // state needed. ----
  typedef enum logic {S_FIRST, S_SECOND} pk_state_t;
  pk_state_t pk_state_q;

  logic [7:0] first_byte_q;

  wire first_eop = fifo_rd_data[8];
  wire [7:0] this_byte = fifo_rd_data[7:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pk_state_q <= S_FIRST;
    end else begin
      unique case (pk_state_q)
        S_FIRST: begin
          if (!fifo_empty && !first_eop) begin
            first_byte_q <= this_byte;
            pk_state_q   <= S_SECOND;
          end
        end
        S_SECOND: begin
          if (!fifo_empty && s_axis_tready_i) pk_state_q <= S_FIRST;
        end
        default: pk_state_q <= S_FIRST;
      endcase
    end
  end

  always_comb begin
    fifo_rd_en      = 1'b0;
    s_axis_tdata_o  = {this_byte, first_byte_q};
    s_axis_tkeep_o  = 2'b11;
    s_axis_tvalid_o = 1'b0;
    s_axis_tlast_o  = 1'b0;

    unique case (pk_state_q)
      S_FIRST: begin
        if (!fifo_empty) begin
          if (first_eop) begin
            s_axis_tdata_o  = {8'h00, this_byte};
            s_axis_tkeep_o  = 2'b01;
            s_axis_tvalid_o = 1'b1;
            s_axis_tlast_o  = 1'b1;
            fifo_rd_en      = s_axis_tready_i;
          end else begin
            fifo_rd_en = 1'b1;
          end
        end
      end
      S_SECOND: begin
        if (!fifo_empty) begin
          s_axis_tdata_o  = {this_byte, first_byte_q};
          s_axis_tkeep_o  = 2'b11;
          s_axis_tlast_o  = first_eop; // this is the *second* byte's eop here
          s_axis_tvalid_o = 1'b1;
          fifo_rd_en      = s_axis_tready_i;
        end
      end
      default: ;
    endcase
  end

endmodule
