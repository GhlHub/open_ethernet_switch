// fifo36_async_2kx18.sv
//
// 2048 x 18 dual-clock FIFO. In synthesis (`SYNTHESIS) this is the hard
// UltraScale+ FIFO36E2 primitive (independent clocks, first-word-fall-through,
// EXTENDED_DATACOUNT word counts in each port's own clock domain); elsewhere a
// behavioral Gray-pointer model with the same visible behavior. The count
// outputs are what make it usable as an elastic buffer: each side sees the
// occupancy in its own domain (delayed by the synchronizer latency).
//
// Contract (both paths): rd_data_o is the head entry whenever !rd_empty_o;
// wr_en_i while wr_full_o and rd_en_i while rd_empty_o are ignored; both
// flags/counts read as full/empty while the reset sequence runs. wr_rst_n must
// be synchronous to wr_clk (asserting it resets both sides).

`ifdef SYNTHESIS
module fifo36_async_2kx18 (
  input  logic        wr_clk,
  input  logic        wr_rst_n,
  input  logic        wr_en_i,
  input  logic [17:0] wr_data_i,
  output logic        wr_full_o,
  output logic [11:0] wr_count_o,

  input  logic        rd_clk,
  input  logic        rd_en_i,
  output logic [17:0] rd_data_o,
  output logic        rd_empty_o,
  output logic [11:0] rd_count_o
);
  wire        full, empty, wr_busy, rd_busy;
  wire [13:0] wrc, rdc;
  wire [63:0] dout;
  wire [7:0]  doutp;

  FIFO36E2 #(
    .CLOCK_DOMAINS          ("INDEPENDENT"),
    .FIRST_WORD_FALL_THROUGH("TRUE"),
    .REGISTER_MODE          ("UNREGISTERED"),
    .READ_WIDTH             (18),
    .WRITE_WIDTH            (18),
    .RDCOUNT_TYPE           ("EXTENDED_DATACOUNT"),
    .WRCOUNT_TYPE           ("EXTENDED_DATACOUNT"),
    .SLEEP_ASYNC            ("FALSE")
  ) u_fifo (
    .CASDIN (64'b0), .CASDINP (8'b0), .CASDOMUX (1'b0), .CASDOMUXEN (1'b1),
    .CASNXTRDEN (1'b0), .CASOREGIMUX (1'b0), .CASOREGIMUXEN (1'b1), .CASPRVEMPTY (1'b0),
    .CASDOUT (), .CASDOUTP (), .CASNXTEMPTY (), .CASPRVRDEN (),
    .DIN    ({48'b0, wr_data_i[15:0]}),
    .DINP   ({6'b0, wr_data_i[17:16]}),
    .INJECTDBITERR (1'b0), .INJECTSBITERR (1'b0),
    .RDCLK  (rd_clk),
    .RDEN   (rd_en_i && !empty && !rd_busy),
    .REGCE  (1'b0),
    .RST    (!wr_rst_n),
    .RSTREG (1'b0),
    .SLEEP  (1'b0),
    .WRCLK  (wr_clk),
    .WREN   (wr_en_i && !full && !wr_busy),
    .DBITERR (), .SBITERR (), .ECCPARITY (),
    .DOUT   (dout), .DOUTP (doutp),
    .EMPTY  (empty), .FULL (full),
    .PROGEMPTY (), .PROGFULL (),
    .RDCOUNT (rdc), .WRCOUNT (wrc),
    .RDERR  (), .WRERR (),
    .RDRSTBUSY (rd_busy), .WRRSTBUSY (wr_busy)
  );

  assign rd_data_o  = {doutp[1:0], dout[15:0]};
  assign rd_empty_o = empty | rd_busy;
  assign wr_full_o  = full | wr_busy;
  assign rd_count_o = rdc[11:0];
  assign wr_count_o = wrc[11:0];
  wire unused_ok = &{1'b0, rdc[13:12], wrc[13:12], dout[63:16], doutp[7:2]};
endmodule
`else
module fifo36_async_2kx18 (
  input  logic        wr_clk,
  input  logic        wr_rst_n,
  input  logic        wr_en_i,
  input  logic [17:0] wr_data_i,
  output logic        wr_full_o,
  output logic [11:0] wr_count_o,

  input  logic        rd_clk,
  input  logic        rd_en_i,
  output logic [17:0] rd_data_o,
  output logic        rd_empty_o,
  output logic [11:0] rd_count_o
);
  localparam int AW = 11;
  localparam int DEPTH = 2048;

  logic [17:0] mem [0:DEPTH-1];
  initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;

  logic [AW:0] wr_bin_q, wr_gray_q, rd_bin_q, rd_gray_q;
  (* ASYNC_REG = "TRUE" *) logic [AW:0] rd_gray_s1, rd_gray_s2, wr_gray_s1, wr_gray_s2;

  function automatic logic [AW:0] g2b(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  wire [AW:0] rd_bin_at_wr = g2b(rd_gray_s2);
  wire [AW:0] wr_bin_at_rd = g2b(wr_gray_s2);
  wire [AW:0] wcount = wr_bin_q - rd_bin_at_wr;
  wire [AW:0] rcount = wr_bin_at_rd - rd_bin_q;

  wire do_write = wr_en_i && (wcount != DEPTH);
  wire do_read  = rd_en_i && (rcount != 0);
  wire [AW:0] wr_next = wr_bin_q + (AW+1)'(do_write);
  wire [AW:0] rd_next = rd_bin_q + (AW+1)'(do_read);

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin_q <= '0; wr_gray_q <= '0; rd_gray_s1 <= '0; rd_gray_s2 <= '0;
    end else begin
      wr_bin_q   <= wr_next;
      wr_gray_q  <= wr_next ^ (wr_next >> 1);
      rd_gray_s1 <= rd_gray_q;
      rd_gray_s2 <= rd_gray_s1;
    end
  end
  always_ff @(posedge wr_clk) if (do_write) mem[wr_bin_q[AW-1:0]] <= wr_data_i;

  always_ff @(posedge rd_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      rd_bin_q <= '0; rd_gray_q <= '0; wr_gray_s1 <= '0; wr_gray_s2 <= '0;
    end else begin
      rd_bin_q   <= rd_next;
      rd_gray_q  <= rd_next ^ (rd_next >> 1);
      wr_gray_s1 <= wr_gray_q;
      wr_gray_s2 <= wr_gray_s1;
    end
  end

  assign rd_data_o  = mem[rd_bin_q[AW-1:0]];
  assign rd_empty_o = (rcount == 0);
  assign wr_full_o  = (wcount == DEPTH);
  assign rd_count_o = rcount;
  assign wr_count_o = wcount;
endmodule
`endif
