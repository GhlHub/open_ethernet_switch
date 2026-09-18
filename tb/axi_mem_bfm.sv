// axi_mem_bfm.sv
//
// Simulation-only AXI4 slave memory model (not meant for synthesis) used
// to verify the DMA engines actually move the right bytes to/from DDR.
// Single-outstanding on each channel, matching the engines under test.
// Byte-addressable backing array so a testbench can easily peek/poke and
// compare against expected frame contents.

module axi_mem_bfm
  import axi_dma_pkg::*;
#(
  parameter int MEM_BYTES = 1 << 16,
  // AXI addresses are absolute (e.g. DDR_BASE_ADDR and up); this model's
  // backing array is only MEM_BYTES long, so every address is rebased by
  // subtracting BASE_ADDR before indexing into it.
  parameter logic [AXI_ADDR_W-1:0] BASE_ADDR = '0
) (
  input logic clk,
  input logic rst_n,

  // AXI4 write slave
  input  logic [AXI_ID_W-1:0]   s_axi_awid,
  input  logic [AXI_ADDR_W-1:0] s_axi_awaddr,
  input  logic [7:0]            s_axi_awlen,
  input  logic [2:0]            s_axi_awsize,
  input  logic [1:0]            s_axi_awburst,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,

  input  logic [AXI_DATA_W-1:0] s_axi_wdata,
  input  logic [AXI_STRB_W-1:0] s_axi_wstrb,
  input  logic                  s_axi_wlast,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,

  output logic [AXI_ID_W-1:0]   s_axi_bid,
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,

  // AXI4 read slave
  input  logic [AXI_ID_W-1:0]   s_axi_arid,
  input  logic [AXI_ADDR_W-1:0] s_axi_araddr,
  input  logic [7:0]            s_axi_arlen,
  input  logic [2:0]            s_axi_arsize,
  input  logic [1:0]            s_axi_arburst,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,

  output logic [AXI_ID_W-1:0]   s_axi_rid,
  output logic [AXI_DATA_W-1:0] s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rlast,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready
);

  logic [7:0] mem [0:MEM_BYTES-1];

  initial begin
    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;
  end

  // ---- write side ----
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate_q;
  logic [AXI_ADDR_W-1:0] waddr_q;
  logic [AXI_ID_W-1:0]   wid_q;

  assign s_axi_awready = (wstate_q == W_IDLE);
  assign s_axi_wready   = (wstate_q == W_DATA);
  assign s_axi_bvalid    = (wstate_q == W_RESP);
  assign s_axi_bid       = wid_q;
  assign s_axi_bresp     = 2'b00; // OKAY

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate_q <= W_IDLE;
    end else begin
      unique case (wstate_q)
        W_IDLE: begin
          if (s_axi_awvalid) begin
            // rebased once here rather than on every mem[] access below --
            // an inline "mem[wide_expr - BASE_ADDR]" index made Icarus
            // Verilog 12.0's elaboration pass scale terribly with MEM_BYTES
            // (fine under ~64KB, minutes-plus/hung at 128KB+); indexing by
            // an already-rebased register is cheap at any size.
            waddr_q  <= s_axi_awaddr - BASE_ADDR;
            wid_q    <= s_axi_awid;
            wstate_q <= W_DATA;
          end
        end
        W_DATA: begin
          if (s_axi_wvalid) begin
            for (int b = 0; b < AXI_STRB_W; b++) begin
              if (s_axi_wstrb[b]) mem[waddr_q + b] = s_axi_wdata[8*b +: 8];
            end
            waddr_q <= waddr_q + AXI_ADDR_W'(AXI_STRB_W);
            if (s_axi_wlast) wstate_q <= W_RESP;
          end
        end
        W_RESP: begin
          if (s_axi_bready) wstate_q <= W_IDLE;
        end
        default: wstate_q <= W_IDLE;
      endcase
    end
  end

  // ---- read side ----
  typedef enum logic [1:0] {R_IDLE, R_DATA} rstate_t;
  rstate_t rstate_q;
  logic [AXI_ADDR_W-1:0] raddr_q;
  logic [AXI_ID_W-1:0]   rid_q;
  logic [7:0]            rlen_q; // beats remaining - 1

  assign s_axi_arready = (rstate_q == R_IDLE);
  assign s_axi_rvalid    = (rstate_q == R_DATA);
  assign s_axi_rid       = rid_q;
  assign s_axi_rresp     = 2'b00;
  assign s_axi_rlast     = (rstate_q == R_DATA) && (rlen_q == 8'd0);

  always_comb begin
    for (int b = 0; b < AXI_STRB_W; b++) begin
      s_axi_rdata[8*b +: 8] = mem[raddr_q + b];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate_q <= R_IDLE;
    end else begin
      unique case (rstate_q)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            raddr_q  <= s_axi_araddr - BASE_ADDR;
            rid_q    <= s_axi_arid;
            rlen_q   <= s_axi_arlen;
            rstate_q <= R_DATA;
          end
        end
        R_DATA: begin
          if (s_axi_rready) begin
            raddr_q <= raddr_q + AXI_ADDR_W'(AXI_STRB_W);
            if (rlen_q == 8'd0) rstate_q <= R_IDLE;
            else                 rlen_q  <= rlen_q - 1'b1;
          end
        end
        default: rstate_q <= R_IDLE;
      endcase
    end
  end

endmodule
