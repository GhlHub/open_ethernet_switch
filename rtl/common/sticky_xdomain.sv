// sticky_xdomain.sv
//
// A sticky event flag that lives in the SOURCE clock domain, is read in the
// DESTINATION domain, and is cleared from the destination domain (CPU
// write-1-to-clear):
//   * event_i (one src_clk pulse) sets the flag; set wins over a clear that
//     arrives the same cycle.
//   * flag_o is the flag synchronized into dst_clk (two flops), masked for
//     MASK_CYCLES dst_clk cycles after clear_i so a read right after the clear
//     cannot see the not-yet-cleared value.
//   * clear_i (one dst_clk pulse) flips a toggle that is synchronized into the
//     source domain, where it clears the flag. Events in the few source
//     cycles between the clear request and its arrival are lost (the flag
//     means "an event since about the clear").
// If src_clk has stopped, a clear is not processed until it returns, and the
// flag reappears after the mask expires.

module sticky_xdomain #(
  parameter int MASK_CYCLES = 16
) (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic event_i,

  input  logic dst_clk,
  input  logic dst_rst_n,
  input  logic clear_i,
  output logic flag_o
);

  logic clr_tog_q;
  logic flag_src_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] clr_sync;
  logic clr_prev_q;

  always_ff @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      clr_sync   <= '0;
      clr_prev_q <= 1'b0;
      flag_src_q <= 1'b0;
    end else begin
      clr_sync   <= {clr_sync[0], clr_tog_q};
      clr_prev_q <= clr_sync[1];
      if (event_i)                        flag_src_q <= 1'b1;
      else if (clr_sync[1] ^ clr_prev_q)  flag_src_q <= 1'b0;
    end
  end

  (* ASYNC_REG = "TRUE" *) logic [1:0] flag_sync;
  logic [$clog2(MASK_CYCLES+1)-1:0] mask_q;

  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      clr_tog_q <= 1'b0;
      flag_sync <= '0;
      mask_q    <= '0;
    end else begin
      flag_sync <= {flag_sync[0], flag_src_q};
      if (clear_i) begin
        clr_tog_q <= ~clr_tog_q;
        mask_q    <= MASK_CYCLES;
      end else if (mask_q != 0) mask_q <= mask_q - 1'b1;
    end
  end

  assign flag_o = flag_sync[1] && (mask_q == 0) && !clear_i;

endmodule
