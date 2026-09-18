// async_fifo.sv
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
  logic [AW:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;

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
      if (do_write) mem[wr_ptr_bin_q[AW-1:0]] <= wr_data_i;
      wr_ptr_bin_q      <= wr_ptr_bin_next;
      wr_ptr_gray_q     <= wr_ptr_gray_next;
      rd_ptr_gray_sync1 <= rd_ptr_gray_q;
      rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
      full_o            <= full_next;
    end
  end

  // ---- read side ----
  logic [AW:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

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
