// tb_mac_adapters.sv
//
// Stand-alone bench for the word-wide MAC adapters:
//   mac_rxd_to_switch_ingress (MAC 32-bit stream, axis_clk 142.86 MHz -> switch
//   16-bit stream, fabric 100 MHz) and switch_egress_to_mac_txd (the reverse,
//   including the per-frame txc beat).
//   A. every frame length 1..40 bytes plus 63/64/65/1518 in both directions,
//      byte-for-byte, with correct tlast and tkeep (partial final word/beat),
//      under random back-pressure on the consuming side
//   B. sustained rate: a 1518-byte frame with the consumer always ready must
//      cross in about one word per fabric cycle (RX: fabric side; TX: fabric
//      side, MAC always ready) -- a byte-serial datapath would take twice as long
//   C. back-to-back frames with no gap (also under back-pressure)

`timescale 1ns/1ps

module tb_mac_adapters;
  logic clk = 0, axis_clk = 0;
  always #5.0   clk = ~clk;         // 100 MHz fabric
  always #3.5   axis_clk = ~axis_clk; // ~142.9 MHz
  logic rst_n = 0, axis_rst_n = 0;

  // ---------------- RX adapter ----------------
  logic [31:0] rx_tdata; logic [3:0] rx_tkeep; logic rx_tlast, rx_tvalid; wire rx_tready;
  wire [15:0] f_tdata; wire [1:0] f_tkeep; wire f_tvalid, f_tlast, f_tuser; logic f_tready;

  mac_rxd_to_switch_ingress u_rx (
    .axis_clk (axis_clk), .axis_rst_n (axis_rst_n), .clk (clk), .rst_n (rst_n),
    .m_axis_rxd_tdata_i (rx_tdata), .m_axis_rxd_tkeep_i (rx_tkeep), .m_axis_rxd_tlast_i (rx_tlast),
    .m_axis_rxd_tvalid_i (rx_tvalid), .m_axis_rxd_tready_o (rx_tready),
    .s_axis_tdata_o (f_tdata), .s_axis_tkeep_o (f_tkeep), .s_axis_tvalid_o (f_tvalid),
    .s_axis_tlast_o (f_tlast), .s_axis_tuser_o (f_tuser), .s_axis_tready_i (f_tready));

  // ---------------- TX adapter ----------------
  logic [15:0] t_tdata; logic [1:0] t_tkeep; logic t_tvalid, t_tlast; wire t_tready;
  wire txc_v, txc_l; logic txc_r;
  wire [31:0] txd_data; wire [3:0] txd_keep; wire txd_last, txd_valid; logic txd_ready;

  switch_egress_to_mac_txd u_tx (
    .clk (clk), .rst_n (rst_n), .axis_clk (axis_clk), .axis_rst_n (axis_rst_n),
    .s_axis_tdata_i (t_tdata), .s_axis_tkeep_i (t_tkeep), .s_axis_tvalid_i (t_tvalid),
    .s_axis_tlast_i (t_tlast), .s_axis_tready_o (t_tready),
    .s_axis_txc_tvalid_o (txc_v), .s_axis_txc_tlast_o (txc_l), .s_axis_txc_tready_i (txc_r),
    .s_axis_txd_tdata_o (txd_data), .s_axis_txd_tkeep_o (txd_keep), .s_axis_txd_tlast_o (txd_last),
    .s_axis_txd_tvalid_o (txd_valid), .s_axis_txd_tready_i (txd_ready));

  int errors = 0;
  bit backpressure;                  // random ready toggling on the consumers
  int seed = 7;

  // MAC side of the TX adapter: txc always ready (models the MAC accepting the control beat),
  // txd_ready follows backpressure; txd only legal after a txc beat -- checked.
  logic txc_seen;
  always @(posedge axis_clk) begin
    txc_r     <= backpressure ? ($urandom(seed) % 3 != 0) : 1'b1;
    txd_ready <= backpressure ? ($urandom(seed) % 3 != 0) : 1'b1;
  end
  int txc_count, txd_frames;
  always @(posedge axis_clk) begin
    if (txc_v && txc_r) begin txc_count <= txc_count + 1; end
    if (txd_valid && txd_ready && txd_last) txd_frames <= txd_frames + 1;
  end
  always @(posedge axis_clk) if (txd_valid && txd_ready && (txc_count - txd_frames) < 1 && !(txc_v && txc_r)) begin
    // a txd beat with no txc issued for this frame
    if (txc_count == txd_frames) begin errors <= errors + 1; $display("FAIL: txd beat before its txc beat"); end
  end

  // fabric consumer of the RX adapter: random backpressure
  always @(posedge clk) f_tready <= backpressure ? ($urandom(seed) % 4 != 0) : 1'b1;

  // ---------------- captures ----------------
  byte rx_cap [$]; int rx_last_seen; int rx_words; int rx_first_cyc, rx_last_cyc; int fcyc;
  always @(posedge clk) fcyc <= fcyc + 1;
  always @(posedge clk) if (f_tvalid && f_tready) begin
    if (rx_words == 0) rx_first_cyc = fcyc;
    rx_words++;
    rx_cap.push_back(byte'(f_tdata[7:0]));
    if (f_tkeep[1]) rx_cap.push_back(byte'(f_tdata[15:8]));
    else if (!f_tlast) begin errors++; $display("FAIL: RX partial tkeep on a non-final word"); end
    if (f_tlast) begin rx_last_seen++; rx_last_cyc = fcyc; end
  end

  byte tx_cap [$]; int tx_last_seen;
  always @(posedge axis_clk) if (txd_valid && txd_ready) begin
    for (int b = 0; b < 4; b++) if (txd_keep[b]) tx_cap.push_back(byte'(txd_data[8*b +: 8]));
    if (txd_keep[3] && !txd_keep[2] || txd_keep[2] && !txd_keep[1] || txd_keep[1] && !txd_keep[0]) begin
      errors++; $display("FAIL: non-contiguous txd tkeep %b", txd_keep);
    end
    if (!txd_last && txd_keep != 4'b1111) begin errors++; $display("FAIL: partial txd tkeep %b on a non-final beat", txd_keep); end
    if (txd_last) tx_last_seen++;
  end

  // ---------------- drivers ----------------
  // Drivers: assign with a non-blocking write, then wait for the edge at which
  // valid && ready are both high (ready read right after the edge is its pre-edge
  // value); the next word is assigned in that same time step, so a word is offered
  // every cycle with no duplicates.
  task automatic rx_send(input byte data[]);
    int n, i, k;
    bit acc;
    n = data.size(); i = 0;
    @(posedge axis_clk);
    while (i < n) begin
      logic [31:0] d; logic [3:0] kp;
      d = '0; kp = '0;
      for (k = 0; k < 4 && i + k < n; k++) begin d[8*k +: 8] = data[i+k]; kp[k] = 1'b1; end
      rx_tdata <= d; rx_tkeep <= kp; rx_tlast <= (i + k >= n); rx_tvalid <= 1'b1;
      @(posedge axis_clk); acc = rx_tready;
      while (!acc) begin @(posedge axis_clk); acc = rx_tready; end
      i += k;
    end
    rx_tvalid <= 1'b0; rx_tlast <= 1'b0;
  endtask

  task automatic tx_send(input byte data[]);
    int n, i;
    bit acc;
    n = data.size();
    @(posedge clk);
    for (i = 0; i < n; i += 2) begin
      t_tdata  <= {(i + 1 < n) ? data[i+1] : 8'h00, data[i]};
      t_tkeep  <= (i + 1 < n) ? 2'b11 : 2'b01;
      t_tlast  <= (i + 2 >= n);
      t_tvalid <= 1'b1;
      @(posedge clk); acc = t_tready;
      while (!acc) begin @(posedge clk); acc = t_tready; end
    end
    t_tvalid <= 1'b0; t_tlast <= 1'b0;
  endtask

  function automatic byte pat(input int len, input int i);
    return byte'((i * 7 + len * 13 + 5) & 8'hFF);
  endfunction

  task automatic check_rx(input string name, input byte exp[]);
    bit ok;
    ok = (rx_cap.size() == exp.size());
    if (ok) for (int i = 0; i < exp.size(); i++) if (rx_cap[i] !== exp[i]) ok = 0;
    if (!ok) begin errors++; $display("FAIL: %s len %0d: got %0d bytes", name, exp.size(), rx_cap.size()); end
    rx_cap.delete();
  endtask
  task automatic check_tx(input string name, input byte exp[]);
    bit ok;
    ok = (tx_cap.size() == exp.size());
    if (ok) for (int i = 0; i < exp.size(); i++) if (tx_cap[i] !== exp[i]) ok = 0;
    if (!ok) begin errors++; $display("FAIL: %s len %0d: got %0d bytes", name, exp.size(), tx_cap.size()); end
    tx_cap.delete();
  endtask

  int lens [$];
  initial begin
    rx_tdata = 0; rx_tkeep = 0; rx_tlast = 0; rx_tvalid = 0; f_tready = 1;
    t_tdata = 0; t_tkeep = 0; t_tlast = 0; t_tvalid = 0; txc_r = 1; txd_ready = 1;
    txc_count = 0; txd_frames = 0; rx_words = 0; rx_last_seen = 0; tx_last_seen = 0; fcyc = 0; backpressure = 0;
    repeat (8) @(posedge clk);
    rst_n = 1; axis_rst_n = 1;
    repeat (20) @(posedge clk);

    for (int l = 1; l <= 40; l++) lens.push_back(l);
    lens.push_back(63); lens.push_back(64); lens.push_back(65); lens.push_back(1518);

    // ---- A: lengths, with and without back-pressure ----
    for (int bp = 0; bp < 2; bp++) begin
      backpressure = (bp == 1);
      foreach (lens[j]) begin
        byte d[]; int L; int t; int want_last;
        L = lens[j]; d = new[L];
        for (int i = 0; i < L; i++) d[i] = pat(L, i);
        // RX
        want_last = rx_last_seen + 1;
        rx_send(d);
        t = 0; while (rx_last_seen < want_last && t < 20000) begin @(posedge clk); t++; end
        repeat (3) @(posedge clk);
        check_rx($sformatf("RX bp=%0d", bp), d);
        // TX
        want_last = tx_last_seen + 1;
        tx_send(d);
        t = 0; while (tx_last_seen < want_last && t < 20000) begin @(posedge axis_clk); t++; end
        repeat (3) @(posedge axis_clk);
        check_tx($sformatf("TX bp=%0d", bp), d);
      end
    end
    if (errors == 0) $display("PASS: A all lengths, RX and TX, with and without back-pressure");

    // ---- B: sustained rate, no back-pressure ----
    backpressure = 0;
    begin
      byte d[]; int L, want_last, t, cyc, words; L = 1518; d = new[L];
      for (int i = 0; i < L; i++) d[i] = pat(L, i);
      words = (L + 1) / 2;
      // RX: MAC offers a beat every axis cycle; measure fabric cycles first word -> last word
      rx_words = 0; want_last = rx_last_seen + 1;
      rx_send(d);
      t = 0; while (rx_last_seen < want_last && t < 20000) begin @(posedge clk); t++; end
      cyc = rx_last_cyc - rx_first_cyc + 1;
      $display("INFO: RX 1518 B -> %0d words in %0d fabric cycles (%0d words per 100 cycles)", words, cyc, (words * 100) / cyc);
      if (cyc > words + words / 20 + 8) begin errors++; $display("FAIL: RX rate too low (%0d cycles for %0d words)", cyc, words); end
      rx_cap.delete();
      // TX: fabric offers a word every cycle; measure how long the last word takes to be accepted
      begin
        int c0, c1;
        want_last = tx_last_seen + 1;
        c0 = fcyc;
        tx_send(d);
        c1 = fcyc;
        cyc = c1 - c0;
        $display("INFO: TX 1518 B -> %0d words accepted in %0d fabric cycles (%0d words per 100 cycles)", words, cyc, (words * 100) / cyc);
        if (cyc > words + words / 20 + 12) begin errors++; $display("FAIL: TX rate too low (%0d cycles for %0d words)", cyc, words); end
        t = 0; while (tx_last_seen < want_last && t < 20000) begin @(posedge axis_clk); t++; end
        repeat (3) @(posedge axis_clk);
        check_tx("TX rate frame", d);
      end
    end
    if (errors == 0) $display("PASS: B sustained rate ~1 word per fabric cycle both ways");

    // ---- C: back-to-back frames ----
    for (int bp = 0; bp < 2; bp++) begin
      backpressure = (bp == 1);
      begin
        byte d0[], d1[], d2[];
        int w;
        d0 = new[65]; d1 = new[64]; d2 = new[200];
        for (int i = 0; i < 65; i++)  d0[i] = pat(65, i);
        for (int i = 0; i < 64; i++)  d1[i] = pat(64, i);
        for (int i = 0; i < 200; i++) d2[i] = pat(200, i);
        w = rx_last_seen + 3;
        fork
          begin rx_send(d0); rx_send(d1); rx_send(d2); end
          begin int t; t = 0; while (rx_last_seen < w && t < 40000) begin @(posedge clk); t++; end end
        join
        repeat (3) @(posedge clk);
        begin
          byte all[$]; bit okc;
          all.delete();
          foreach (d0[i]) all.push_back(d0[i]); foreach (d1[i]) all.push_back(d1[i]); foreach (d2[i]) all.push_back(d2[i]);
          okc = (rx_cap.size() == all.size());
          if (okc) for (int i = 0; i < all.size(); i++) if (rx_cap[i] !== all[i]) okc = 0;
          if (!okc) begin errors++; $display("FAIL: RX back-to-back bp=%0d (%0d bytes, expected %0d)", bp, rx_cap.size(), all.size()); end
          rx_cap.delete();
        end
        w = tx_last_seen + 3;
        fork
          begin tx_send(d0); tx_send(d1); tx_send(d2); end
          begin int t; t = 0; while (tx_last_seen < w && t < 40000) begin @(posedge axis_clk); t++; end end
        join
        repeat (3) @(posedge axis_clk);
        begin
          byte all[$]; bit okc;
          all.delete();
          foreach (d0[i]) all.push_back(d0[i]); foreach (d1[i]) all.push_back(d1[i]); foreach (d2[i]) all.push_back(d2[i]);
          okc = (tx_cap.size() == all.size());
          if (okc) for (int i = 0; i < all.size(); i++) if (tx_cap[i] !== all[i]) okc = 0;
          if (!okc) begin errors++; $display("FAIL: TX back-to-back bp=%0d (%0d bytes, expected %0d)", bp, tx_cap.size(), all.size()); end
          tx_cap.delete();
        end
      end
    end
    if (errors == 0) $display("PASS: C back-to-back frames, with and without back-pressure");

    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end

  initial begin #200_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
