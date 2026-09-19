// tb_rgmii_rx_elastic.sv
//
// Elastic RX buffer (rgmii_rx_elastic.sv + fifo36_async_2kx18.sv) with the two
// clocks offset by PPM parts per million (positive = the RGMII receive clock is
// faster than gtx_clk). Back-to-back random frames (64..1518 bytes, minimum-ish
// inter-frame gap, some with an RX_ER byte) go in; every output frame must be
// byte-for-byte identical, in order, with the output inter-frame gap never
// below 8 cycles, idle status data preserved, and no overflow/underrun.
// The run must also show the adaptation actually happened (idle dropped when
// the receive clock is faster, idle inserted when slower).

`timescale 1ns/1ps

module tb_rgmii_rx_elastic #(
  parameter int PPM    = 500,
  parameter int NFRAME = 250
);
  real rxc_half, gtx_half;
  logic rxc = 0, gtx = 0;
  initial begin
    rxc_half = 4.0 / (1.0 + PPM * 1.0e-6);
    gtx_half = 4.0;
  end
  always #(rxc_half) rxc = ~rxc;
  always #(gtx_half) gtx = ~gtx;

  logic rxc_rst_n = 0, gtx_rst_n = 0;
  logic       in_dv = 0, in_er = 0;
  logic [7:0] in_data = 8'h0D;
  wire  [7:0] out_d;
  wire        out_dv, out_er, ovf_evt, und_evt;
  logic       ovf = 0, und = 0;
  always @(posedge rxc) if (ovf_evt) ovf <= 1;
  always @(posedge gtx) if (und_evt) und <= 1;

  rgmii_rx_elastic dut (
    .rxc (rxc), .rxc_rst_n (rxc_rst_n), .in_dv (in_dv), .in_er (in_er), .in_data (in_data),
    .gtx_clk (gtx), .gtx_rst_n (gtx_rst_n),
    .gmii_rxd_o (out_d), .gmii_rx_dv_o (out_dv), .gmii_rx_er_o (out_er),
    .overflow_evt_o (ovf_evt), .underrun_evt_o (und_evt));

  // ---- expected data ----
  localparam int MAXB = 1 << 20;
  logic [8:0] exp_mem [0:MAXB-1];       // {er, byte}
  int         exp_len [0:NFRAME-1];
  int         exp_wr;
  int         sent;
  logic       gen_done;

  // ---- generator (rxc domain) ----
  int seed = 32'h1234_5678 + PPM;
  int gap_left, len_left, cur_frame, er_pos;
  logic gen_active;
  int   idle_cnt, nlen;

  always @(posedge rxc) begin
    if (!rxc_rst_n) begin
      in_dv <= 0; in_er <= 0; in_data <= 8'h0D;
      gap_left <= 200; len_left <= 0; sent <= 0; exp_wr <= 0; gen_done <= 0;
    end else if (sent < NFRAME || len_left > 0) begin
      if (len_left > 0) begin
        logic [7:0] b;
        b = $urandom(seed);
        in_dv   <= 1;
        in_er   <= (len_left == er_pos);
        in_data <= b;
        exp_mem[exp_wr] = {(len_left == er_pos), b};
        exp_wr = exp_wr + 1;
        len_left <= len_left - 1;
        if (len_left == 1) begin
          // choose the gap (mostly minimum)
          gap_left <= (($urandom(seed) % 4) == 0) ? 12 + ($urandom(seed) % 30) : 12;
        end
      end else if (gap_left > 0) begin
        in_dv <= 0; in_er <= 0; in_data <= 8'h0D;
        gap_left <= gap_left - 1;
      end else begin
        // start a frame
        nlen = 64 + ($urandom(seed) % 1455);
        len_left <= nlen;
        exp_len[sent] = nlen;
        er_pos <= (($urandom(seed) % 20) == 0) ? 10 : -1;
        sent <= sent + 1;
        cur_frame <= sent;
        in_dv <= 0; in_er <= 0; in_data <= 8'h0D;
      end
    end else begin
      in_dv <= 0; in_er <= 0; in_data <= 8'h0D;
      gen_done <= 1;
    end
  end
  // ---- checker (gtx domain) ----
  int rcv_frames, rd_idx, byte_errs, mism_len, idle_run, min_idle, ridx0;
  logic prev_out_dv, primed;
  int total_bytes_out;
  int bad_idle;

  always @(posedge gtx) begin
    if (!gtx_rst_n) begin
      rcv_frames <= 0; rd_idx <= 0; byte_errs <= 0; mism_len <= 0; idle_run <= 0;
      min_idle <= 1000; prev_out_dv <= 0; primed <= 0; total_bytes_out <= 0; bad_idle <= 0;
    end else begin
      prev_out_dv <= out_dv;
      if (out_dv) begin
        if (!prev_out_dv) begin
          if (primed && idle_run < min_idle) min_idle <= idle_run;
          primed <= 1;
          idle_run <= 0;
          ridx0 <= rd_idx;
        end
        if (exp_mem[rd_idx] !== {out_er, out_d}) byte_errs <= byte_errs + 1;
        rd_idx <= rd_idx + 1;
        total_bytes_out <= total_bytes_out + 1;
      end else begin
        idle_run <= idle_run + 1;
        if (primed && out_d !== 8'h0D && rd_idx > 0 && idle_run > 0) bad_idle <= bad_idle + 1;
        if (prev_out_dv) begin
          rcv_frames <= rcv_frames + 1;
          if (exp_len[rcv_frames] != rd_idx - ridx0) mism_len <= mism_len + 1;
        end
      end
    end
  end

  // ---- adaptation activity ----
  int drops, stalls;
  always @(posedge rxc) if (rxc_rst_n && dut.drop) drops <= drops + 1;
  always @(posedge gtx) if (gtx_rst_n && !dut.do_pop && !dut.in_frame && !dut.rd_empty) stalls <= stalls + 1;
  initial begin drops = 0; stalls = 0; end

  int errors;
  initial begin
    errors = 0;
    repeat (10) @(posedge rxc);
    rxc_rst_n = 1;
    repeat (3) @(posedge gtx);
    gtx_rst_n = 1;
    wait (gen_done);
    repeat (3000) @(posedge gtx);

    if (rcv_frames != NFRAME) begin errors++; $display("FAIL: received %0d frames, sent %0d", rcv_frames, NFRAME); end
    if (byte_errs != 0)       begin errors++; $display("FAIL: %0d byte errors", byte_errs); end
    if (mism_len != 0)        begin errors++; $display("FAIL: %0d frame length mismatches", mism_len); end
    if (min_idle < 8)         begin errors++; $display("FAIL: output inter-frame gap shrank to %0d", min_idle); end
    if (bad_idle != 0)        begin errors++; $display("FAIL: idle status data altered (%0d)", bad_idle); end
    if (ovf || und)           begin errors++; $display("FAIL: flags ovf=%b und=%b", ovf, und); end
    if (PPM > 0 && drops == 0)  begin errors++; $display("FAIL: faster rxc but no idle was dropped"); end
    if (PPM < 0 && stalls == 0) begin errors++; $display("FAIL: slower rxc but no idle was inserted"); end
    $display("PPM=%0d frames=%0d bytes=%0d drops=%0d stalls=%0d min_out_gap=%0d", PPM, rcv_frames, total_bytes_out, drops, stalls, min_idle);
    $display("%s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
