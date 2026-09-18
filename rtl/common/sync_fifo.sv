// sync_fifo.sv
//
// Plain single-clock synchronous FIFO used for the learn/lookup request
// queues. DEPTH need not be a power of two (a counter is used for
// full/empty rather than pointer-wrap comparison).

module sync_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 16
) (
  input  logic             clk,
  input  logic             rst_n,

  input  logic             wr_en_i,
  input  logic [WIDTH-1:0] wr_data_i,
  output logic             full_o,

  input  logic             rd_en_i,
  output logic [WIDTH-1:0] rd_data_o,
  output logic             empty_o
);

  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW-1:0]    wr_ptr_q, rd_ptr_q;
  logic [AW:0]      count_q;

  assign full_o  = (count_q == (AW+1)'(DEPTH));
  assign empty_o = (count_q == '0);

  wire do_wr = wr_en_i && !full_o;
  wire do_rd = rd_en_i && !empty_o;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      if (do_wr) begin
        mem[wr_ptr_q] <= wr_data_i;
        wr_ptr_q      <= (wr_ptr_q == AW'(DEPTH-1)) ? '0 : wr_ptr_q + 1'b1;
      end
      if (do_rd) begin
        rd_ptr_q <= (rd_ptr_q == AW'(DEPTH-1)) ? '0 : rd_ptr_q + 1'b1;
      end
      case ({do_wr, do_rd})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

  assign rd_data_o = mem[rd_ptr_q];

endmodule
