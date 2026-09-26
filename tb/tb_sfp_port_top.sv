// tb_sfp_port_top.sv
//
// Self-checking loopback test for sfp_port_top.sv: the GTH-parallel-
// interface TX output is wired straight back into the RX input (same
// strategy as tb_sfp_1000base_x_pcs.sv -- validates all the hand-written
// digital logic in the chain, not real transceiver/optical behavior; no
// GTHE4_CHANNEL primitive is instantiated, per sfp_port_top.sv's header).
// A frame pushed into the switch egress AXI4-Stream (s_axis_*) travels
// switch_egress_to_mac_txd -> MAC TX -> PCS TX -> [loopback] -> PCS RX ->
// MAC RX -> mac_rxd_to_switch_ingress -> switch ingress AXI4-Stream
// (m_axis_*), exercising every new/reused block in the SFP port at once.
//
//   A. wait for sync_ok_o after reset (PCS needs idle cycles to acquire
//      code-group sync -- see gmii_1000base_x_rx.sv, which gates all RX
//      output on it), then one frame with random backpressure on both
//      switch-side ends -> byte content and tlast position preserved
//   B. a second frame immediately after -> confirms every stage's state
//      (MAC TX/RX descriptor logic, both adapters, the PCS TX/RX codecs)
//      resets cleanly between frames

`timescale 1ns/1ps

module tb_sfp_port_top;

  logic clk = 0;
  logic rst_n = 0;
  always #4 clk = ~clk; // 125 MHz (switch fabric side)

  logic axis_clk = 0;
  logic axis_rst_n = 0;
  always #(10.0/3) axis_clk = ~axis_clk; // 150 MHz-equivalent (MAC side)

  logic gtx_clk = 0;
  logic gtx_rst_n = 0;
  always #4 gtx_clk = ~gtx_clk; // 125 MHz-equivalent (GMII/PCS side)

  // gth_clk must be gtx_clk/2, phase-related -- see
  // sfp_1000base_x_pcs.sv's header (this is the exact same requirement/
  // phase derivation as tb_sfp_1000base_x_pcs.sv's own gth_clk, reused
  // verbatim here: gtx_clk's first posedge is at t=4, period 8, so
  // gth_clk's rising edge is placed at t=16 then every 16ns).
  logic gth_clk = 0;
  logic gth_rst_n = 0;
  initial begin
    #16 gth_clk = 1;
    forever #8 gth_clk = ~gth_clk;
  end

  logic [15:0] txdata;
  logic [1:0]  txcharisk;
  logic [15:0] rxdata;
  logic [1:0]  rxcharisk;
  logic       sync_ok;

  // GTH-parallel-interface loopback (no real GTH/SFP/fiber in the loop)
  assign rxdata    = txdata;
  assign rxcharisk = txcharisk;

  logic [15:0] m_tdata;
  logic [1:0]  m_tkeep;
  logic        m_tvalid;
  logic        m_tlast;
  logic        m_tuser;
  logic        m_tready;

  logic [15:0] s_tdata;
  logic [1:0]  s_tkeep;
  logic        s_tvalid;
  logic        s_tlast;
  logic        s_tready;

  // AXI4-Lite write side, driven by u_axi_write below
  logic [17:0] axi_awaddr;
  logic        axi_awvalid;
  logic        axi_awready;
  logic [31:0] axi_wdata;
  logic [3:0]  axi_wstrb;
  logic        axi_wvalid;
  logic        axi_wready;
  logic [1:0]  axi_bresp;
  logic        axi_bvalid;
  logic        axi_bready;

  // ---- CDC safety monitor for the MAC's hand-built Gray pointers ----
  // A Gray-coded pointer is only safe to synchronize if it changes by exactly
  // one bit per update in its own clock domain. Count any update that flips
  // more than one bit (each pointer sampled in the domain that writes it),
  // per pointer, once both resets have been released for a while.
  int gray_bad [6];
  int gray_multibit;
  bit mon_en = 1'b0;
  logic [15:0] g_q [6];
  logic [15:0] g_now [6];
  always_comb begin
    g_now[0] = 16'(dut.u_mac.tx_data_rd_gray);
    g_now[1] = 16'(dut.u_mac.tx_desc_rd_gray);
    g_now[2] = 16'(dut.u_mac.rx_desc_wr_gray);
    g_now[3] = 16'(dut.u_mac.rx_data_rd_gray);
    g_now[4] = 16'(dut.u_mac.rx_desc_rd_gray);
    g_now[5] = 16'(dut.u_mac.tx_desc_wr_gray);
  end
  initial begin
    for (int i = 0; i < 6; i++) begin gray_bad[i] = 0; g_q[i] = '0; end
    gray_multibit = 0;
    wait (gtx_rst_n && axis_rst_n);
    repeat (50) @(posedge gtx_clk);
    mon_en = 1'b1;
  end
  always @(posedge gtx_clk) begin
    for (int i = 0; i < 3; i++) begin
      if (mon_en && pop16(g_now[i] ^ g_q[i]) > 1) begin gray_bad[i]++; end
      g_q[i] <= g_now[i];
    end
  end
  always @(posedge axis_clk) begin
    for (int i = 3; i < 6; i++) begin
      if (mon_en && pop16(g_now[i] ^ g_q[i]) > 1) begin gray_bad[i]++; end
      g_q[i] <= g_now[i];
    end
  end
  function automatic int pop16(input logic [15:0] v);
    int c = 0;
    for (int b = 0; b < 16; b++) if (v[b] === 1'b1) c++;
    return c;
  endfunction
  function automatic int gray_total();
    int t = 0;
    for (int i = 0; i < 6; i++) t += gray_bad[i];
    return t;
  endfunction

  sfp_port_top dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .axis_clk         (axis_clk),
    .axis_rst_n       (axis_rst_n),
    .gtx_clk          (gtx_clk),
    .gtx_rst_n        (gtx_rst_n),
    .gth_clk          (gth_clk),
    .gth_rst_n        (gth_rst_n),
    .clk_en           (1'b1),

    .txdata_o         (txdata),
    .txcharisk_o      (txcharisk),
    .rxdata_i         (rxdata),
    .rxcharisk_i      (rxcharisk),
    .rxdisperr_i      (2'b00),
    .rxnotintable_i   (2'b00),
    .sync_ok_o        (sync_ok),

    .m_axis_tdata     (m_tdata),
    .m_axis_tkeep     (m_tkeep),
    .m_axis_tvalid    (m_tvalid),
    .m_axis_tlast     (m_tlast),
    .m_axis_tuser     (m_tuser),
    .m_axis_tready    (m_tready),

    .s_axis_tdata     (s_tdata),
    .s_axis_tkeep     (s_tkeep),
    .s_axis_tvalid    (s_tvalid),
    .s_axis_tlast     (s_tlast),
    .s_axis_tready    (s_tready),

    .s_axi_awaddr     (axi_awaddr),
    .s_axi_awvalid    (axi_awvalid),
    .s_axi_awready    (axi_awready),
    .s_axi_wdata      (axi_wdata),
    .s_axi_wstrb      (axi_wstrb),
    .s_axi_wvalid     (axi_wvalid),
    .s_axi_wready     (axi_wready),
    .s_axi_bresp      (axi_bresp),
    .s_axi_bvalid     (axi_bvalid),
    .s_axi_bready     (axi_bready),
    .s_axi_araddr     (18'd0),
    .s_axi_arvalid    (1'b0),
    .s_axi_arready    (),
    .s_axi_rdata      (),
    .s_axi_rresp      (),
    .s_axi_rvalid     (),
    .s_axi_rready     (1'b1),

    .interrupt        (),
    .mac_irq          ()
  );

  int errors = 0;

  task automatic wait_cycles(input int n); repeat (n) @(posedge clk); endtask

  // ---- minimal AXI4-Lite write (axis_clk domain), used only to set the
  // MAC's TX/RX enable bits (reg_tc[28] @ 0x408, reg_rcw1[28] @ 0x404 --
  // both default to 0 = disabled; see open_eth_mac_1g_switch.sv) before
  // any traffic can flow ----
  task automatic axi_write(input logic [17:0] addr, input logic [31:0] data);
    axi_awaddr  <= addr;
    axi_awvalid <= 1'b1;
    axi_wdata   <= data;
    axi_wstrb   <= 4'hf;
    axi_wvalid  <= 1'b1;
    axi_bready  <= 1'b1;
    @(posedge axis_clk);
    while (!axi_awready) @(posedge axis_clk);
    axi_awvalid <= 1'b0;
    while (!axi_wready) @(posedge axis_clk);
    axi_wvalid  <= 1'b0;
    while (!axi_bvalid) @(posedge axis_clk);
    @(posedge axis_clk);
  endtask

  // ---- drive the switch egress source (clk domain), packed 2 bytes/word ----
  task automatic drive_egress_frame(input byte data[]);
    int n, i;
    logic [15:0] word;
    logic [1:0]  keep;
    bit          is_last;
    n = data.size();
    i = 0;
    while (i < n) begin
      if (i + 1 < n) begin
        word    = {data[i+1], data[i]};
        keep    = 2'b11;
        is_last = (i + 2 >= n);
      end else begin
        word    = {8'h00, data[i]};
        keep    = 2'b01;
        is_last = 1'b1;
      end
      s_tdata  <= word;
      s_tkeep  <= keep;
      s_tvalid <= 1'b1;
      s_tlast  <= is_last;
      @(posedge clk);
      while (!s_tready) @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
  endtask

  // ---- sole driver of m_tready, mode-controlled backpressure ----
  int bp_mode = 0;
  initial begin
    m_tready = 1'b0;
    forever begin
      @(posedge clk);
      case (bp_mode)
        1:       m_tready <= ($urandom_range(0, 3) != 0);
        2:       m_tready <= 1'b1;
        default: m_tready <= 1'b0;
      endcase
    end
  end

  // ---- capture the switch ingress sink ----
  byte cap_bytes[$];
  int  cap_tlast_idx;
  int  cap_ends[$]; // cap_bytes.size() after each frame's last byte

  task automatic cap_reset();
    cap_bytes.delete();
    cap_ends.delete();
    cap_tlast_idx = -1;
  endtask

  always_ff @(posedge clk) begin
    if (m_tvalid && m_tready) begin
      cap_bytes.push_back(byte'(m_tdata[7:0]));
      if (m_tkeep[1]) cap_bytes.push_back(byte'(m_tdata[15:8]));
      if (m_tlast) begin
        cap_tlast_idx = cap_bytes.size() - 1;
        cap_ends.push_back(cap_bytes.size());
      end
      if (m_tuser !== 1'b0) begin
        $display("FAIL: m_axis_tuser unexpectedly set");
        errors++;
      end
    end
  end

  task automatic run_one_frame(input byte data[], input string label);
    cap_reset();
    drive_egress_frame(data);
    wait_cycles(1500); // full MAC+PCS+CDC round trip, generous margin
    if (cap_bytes.size() != data.size()) begin
      $display("FAIL: %s received %0d bytes, expected %0d", label, cap_bytes.size(), data.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < data.size(); i++) if (cap_bytes[i] !== data[i]) ok = 1'b0;
      if (cap_tlast_idx != data.size() - 1) ok = 1'b0;
      if (ok) $display("PASS: %s frame reproduced exactly (%0d bytes) through the full SFP port round trip", label, data.size());
      else begin
        $display("FAIL: %s content/tlast mismatch", label);
        errors++;
      end
    end
  endtask

  initial begin
    s_tdata  = '0;
    s_tkeep  = '0;
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;

    axi_awaddr  = '0;
    axi_awvalid = 1'b0;
    axi_wdata   = '0;
    axi_wstrb   = '0;
    axi_wvalid  = 1'b0;
    axi_bready  = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge axis_clk);
    axis_rst_n = 1'b1;
    repeat (5) @(posedge gtx_clk);
    gtx_rst_n = 1'b1;
    repeat (5) @(posedge gth_clk);
    gth_rst_n = 1'b1;

    repeat (10) @(posedge axis_clk);
    axi_write(18'h00408, 32'h1000_0000); // reg_tc[28]   = 1: TX enable
    axi_write(18'h00404, 32'h1200_0000); // reg_rcw1[28] = 1: RX enable
                                          // (bit 25 preserves the reset default)

    // let the PCS acquire code-group sync before sending any traffic
    wait (sync_ok);
    wait_cycles(20);

    if (!sync_ok) begin
      $display("FAIL: sync_ok_o never asserted");
      errors++;
    end else begin
      $display("PASS: sync_ok_o asserted");
    end

    // Frame lengths below the MAC's 60-byte minimum get zero-padded on
    // TX (open_eth_mac_1g_switch.sv: `if (tx_length_gmii < 60) tx_state
    // <= TX_PAD;`, standard IEEE 802.3 behavior) -- both test frames stay
    // at or above 60 bytes so the exact-content comparison below holds.

    // ---- test A: one frame, random backpressure, odd length ----
    bp_mode = 1;
    begin
      byte data[];
      data = new[73];
      for (int i = 0; i < 73; i++) data[i] = byte'(i + 8'h10);
      run_one_frame(data, "testA");
    end
    bp_mode = 0;

    // ---- test B: a second frame right after, even length, exactly the
    // 60-byte minimum ----
    bp_mode = 2;
    begin
      byte data[];
      data = new[60];
      for (int i = 0; i < 60; i++) data[i] = byte'(i + 8'h60);
      run_one_frame(data, "testB");
    end
    bp_mode = 0;

    // ---- test C: stress -- 20 back-to-back 600-byte frames (~12 KB, three
    // times the MAC's 4 KB transmit buffer), so the transmit buffer must be
    // recycled several times through the (deliberately one-word-per-clock)
    // publication of the data read pointer, and receive buffer space likewise
    bp_mode = 2;
    cap_reset();
    begin
      int nf = 20;
      int len = 600;
      byte data[];
      for (int f = 0; f < nf; f++) begin
        data = new[len];
        for (int i = 0; i < len; i++) data[i] = byte'(f * 13 + i * 3 + 1);
        drive_egress_frame(data);
      end
      wait_cycles(40000);
      begin
        bit ok;
        ok = (cap_ends.size() == nf) && (cap_bytes.size() == nf * len);
        for (int f = 0; f < nf && ok; f++)
          for (int i = 0; i < len; i++)
            if (cap_bytes[f * len + i] !== byte'(f * 13 + i * 3 + 1)) ok = 1'b0;
        for (int f = 0; f < cap_ends.size() && ok; f++)
          if (cap_ends[f] != (f + 1) * len) ok = 1'b0;
        if (ok) $display("PASS: testC %0d back-to-back %0d-byte frames all reproduced in order through the recycled buffers", nf, len);
        else begin
          $display("FAIL: testC stress (frames received=%0d bytes=%0d, expected %0d frames / %0d bytes)", cap_ends.size(), cap_bytes.size(), nf, nf * len);
          errors++;
        end
      end
    end

    gray_multibit = gray_total();
    if (gray_multibit != 0) begin
      $display("FAIL: MAC Gray pointers changed more than one bit at once (tx_data_rd=%0d tx_desc_rd=%0d rx_desc_wr=%0d rx_data_rd=%0d rx_desc_rd=%0d tx_desc_wr=%0d): unsafe to synchronize",
               gray_bad[0], gray_bad[1], gray_bad[2], gray_bad[3], gray_bad[4], gray_bad[5]);
      errors++;
    end else $display("PASS: every MAC Gray pointer changed exactly one bit per update (safe to synchronize)");
    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
