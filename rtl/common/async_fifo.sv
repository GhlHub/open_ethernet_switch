// async_fifo.sv
//
// Dual-clock CDC FIFO. In synthesis (`SYNTHESIS defined) this is a thin
// wrapper around AMD's xpm_fifo_async, which carries its own vendor-supplied
// CDC constraints and is recognized as a safe crossing by report_cdc. Every
// other tool (Icarus, Verilator, and xsim without -d SYNTHESIS) gets the
// behavioral Gray-pointer model below, because XPM cannot be simulated
// outside Vivado -- the same real/portable split rtl/pl_gmii/
// open_eth_mac_1g_switch.sv uses for xpm_memory_sdpram. The XPM path is
// exercised by `make xsim-async-fifo-xpm` (Vivado xsim, tb_async_fifo).
//
// Contract both paths honor: first-word-fall-through read (rd_data_o is the
// head entry whenever !empty_o; rd_en_i pops it); wr_en_i while full_o and
// rd_en_i while empty_o are ignored; full_o/empty_o are registered flags.
// Known differences: (1) XPM's capacity and flag latency differ by a word or
// two and a few cycles from the model; (2) XPM has ONE reset, synchronous to
// wr_clk (wr_rst_n must already be synchronized to wr_clk, as everywhere in
// this project), so rd_rst_n is only used by the model -- the read side
// resets when the write-side reset does; (3) after reset the XPM FIFO is busy
// for a few cycles, during which full_o/empty_o report full/empty. DEPTH is
// raised to the XPM minimum of 16 if smaller.
//
// Original behavioral-model notes:
//
// Standard dual-clock (Gray-code pointer) CDC FIFO, first use in this
// project -- needed for the PS GEM bridge, whose GEM-facing side must
// stay at the GEM FIFO interface's own required clock (~125MHz-class, to
// sustain full gigabit at 8-bit width) while the switch fabric side runs
// at 62.5MHz. DEPTH must be a power of 2 (needed for clean Gray-code
// wrap-around comparison); the memory array itself follows the same
// register-indexed-write pattern as rtl/common/sync_fifo.sv (proven safe
// under Icarus Verilog 12.0 by extensive reuse throughout this project,
// despite superficially resembling the *different*, confirmed-broken
// variable-indexed-write patterns documented elsewhere -- see this
// project's other modules for those specifics).
//
// Classic two-flop synchronizer per direction (Cummings' well-known
// design): each side keeps a Gray-coded copy of its own pointer,
// registers it into the other clock domain through two flops, and
// compares Gray codes directly for full/empty -- never converts the
// synchronized copy back to binary (Gray code changes by exactly one bit
// per increment, so a synchronizer sampling a mid-transition value still
// lands on either the old or new adjacent value, both valid).
//
// full_o/empty_o are themselves REGISTERED, not purely combinational --
// this is deliberate, not a simplification: computing them combinationally
// from a same-cycle "next pointer" creates a real loop (the next pointer
// depends on whether this write/read is allowed, which depends on full/
// empty, which would depend on the next pointer...). Registering them
// breaks that by feeding back only the *previous* cycle's full/empty
// value into this cycle's do_write/do_read gating, exactly like a
// counter reading its own current output to compute its next state.
// Consumers see full/empty a cycle "late" relative to the absolute
// logical minimum in some corner cases; that's the standard, safe-
// direction (never incorrectly permissive) behavior for this design.

`ifdef SYNTHESIS
module async_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 64 // must be a power of 2
) (
  input  logic             wr_clk,
  input  logic             wr_rst_n,
  input  logic             wr_en_i,
  input  logic [WIDTH-1:0] wr_data_i,
  output logic             full_o,

  input  logic             rd_clk,
  input  logic             rd_rst_n,
  input  logic             rd_en_i,
  output logic [WIDTH-1:0] rd_data_o,
  output logic             empty_o
);

  localparam int XDEPTH = (DEPTH < 16) ? 16 : DEPTH;

  wire xfull, xempty, wr_rst_busy, rd_rst_busy;
  wire unused_ok = &{1'b0, rd_rst_n};

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE   ((XDEPTH <= 512) ? "distributed" : "block"),
    .ECC_MODE           ("no_ecc"),
    .RELATED_CLOCKS     (0),
    .SIM_ASSERT_CHK     (0),
    .FIFO_WRITE_DEPTH   (XDEPTH),
    .WRITE_DATA_WIDTH   (WIDTH),
    .READ_DATA_WIDTH    (WIDTH),
    .USE_ADV_FEATURES   ("0000"),
    .READ_MODE          ("fwft"),
    .FIFO_READ_LATENCY  (0),
    .CDC_SYNC_STAGES    (2),
    .DOUT_RESET_VALUE   ("0"),
    .FULL_RESET_VALUE   (0),
    .WAKEUP_TIME        (0)
  ) u_xpm_fifo (
    .sleep         (1'b0),
    .rst           (!wr_rst_n),
    .wr_clk        (wr_clk),
    .wr_en         (wr_en_i && !xfull && !wr_rst_busy),
    .din           (wr_data_i),
    .full          (xfull),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (rd_clk),
    .rd_en         (rd_en_i && !xempty && !rd_rst_busy),
    .dout          (rd_data_o),
    .empty         (xempty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  assign full_o  = xfull  | wr_rst_busy;
  assign empty_o = xempty | rd_rst_busy;

endmodule
`else
module async_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 64 // must be a power of 2
) (
  input  logic             wr_clk,
  input  logic             wr_rst_n,
  input  logic             wr_en_i,
  input  logic [WIDTH-1:0] wr_data_i,
  output logic             full_o,

  input  logic             rd_clk,
  input  logic             rd_rst_n,
  input  logic             rd_en_i,
  output logic [WIDTH-1:0] rd_data_o,
  output logic             empty_o
);

  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [0:DEPTH-1];

  // Both pointer-register pairs are declared up front, ahead of either
  // side's always_ff block: each side's synchronizer reads the *other*
  // side's registered pointer (rd_ptr_gray_q on the write side below,
  // wr_ptr_gray_q on the read side further down), and Icarus Verilog
  // 13.0 (unlike 12.0) requires a signal's declaration to textually
  // precede a procedural reference to it within the same module.
  logic [AW:0] wr_ptr_bin_q, wr_ptr_gray_q;
  logic [AW:0] rd_ptr_bin_q, rd_ptr_gray_q;

  // ---- write side ----
  (* ASYNC_REG = "TRUE" *) logic [AW:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;

  wire do_write = wr_en_i && !full_o;
  wire [AW:0] wr_ptr_bin_next  = wr_ptr_bin_q + (AW+1)'(do_write);
  wire [AW:0] wr_ptr_gray_next = wr_ptr_bin_next ^ (wr_ptr_bin_next >> 1);
  wire full_next = (wr_ptr_gray_next == {~rd_ptr_gray_sync2[AW:AW-1], rd_ptr_gray_sync2[AW-2:0]});

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_ptr_bin_q      <= '0;
      wr_ptr_gray_q      <= '0;
      rd_ptr_gray_sync1 <= '0;
      rd_ptr_gray_sync2 <= '0;
      full_o            <= 1'b0;
    end else begin
      wr_ptr_bin_q      <= wr_ptr_bin_next;
      wr_ptr_gray_q     <= wr_ptr_gray_next;
      rd_ptr_gray_sync1 <= rd_ptr_gray_q;
      rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
      full_o            <= full_next;
    end
  end

  // Memory write: its own block WITHOUT the async reset above. A memory
  // array written from inside an async-reset block cannot be inferred as
  // RAM (Vivado builds it from flip-flops and a large read mux); written
  // here it maps to distributed (LUT) RAM. The array is zero-initialized so
  // simulation never reads X -- entries are only meaningful when !empty_o
  // regardless of that value.
  initial begin
    for (int i = 0; i < DEPTH; i++) mem[i] = '0;
  end
  always_ff @(posedge wr_clk) begin
    if (do_write) mem[wr_ptr_bin_q[AW-1:0]] <= wr_data_i;
  end

  // ---- read side ----
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

  wire do_read = rd_en_i && !empty_o;
  wire [AW:0] rd_ptr_bin_next  = rd_ptr_bin_q + (AW+1)'(do_read);
  wire [AW:0] rd_ptr_gray_next = rd_ptr_bin_next ^ (rd_ptr_bin_next >> 1);
  wire empty_next = (rd_ptr_gray_next == wr_ptr_gray_sync2);

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_ptr_bin_q      <= '0;
      rd_ptr_gray_q      <= '0;
      wr_ptr_gray_sync1 <= '0;
      wr_ptr_gray_sync2 <= '0;
      empty_o           <= 1'b1;
    end else begin
      rd_ptr_bin_q      <= rd_ptr_bin_next;
      rd_ptr_gray_q     <= rd_ptr_gray_next;
      wr_ptr_gray_sync1 <= wr_ptr_gray_q;
      wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
      empty_o           <= empty_next;
    end
  end

  assign rd_data_o = mem[rd_ptr_bin_q[AW-1:0]];

endmodule
`endif
