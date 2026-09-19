// tb_mac_reset_reclock.sv
//
// Checks the reset reclocking added to open_eth_mac_1g_switch.sv: every
// reset input is treated as asynchronous and reclocked into each clock
// domain that uses it (s_axi_lite_clk, axis_clk, gtx_clk).
//
//   A. power-up: all resets low; released at an arbitrary (non-clock-edge)
//      time, each domain's internal reset releases within a bounded number
//      of that domain's clocks (2 in the 150 MHz domains, a few more in the
//      GMII domain, which goes through a launch flop and its own synchronizer)
//   B. asserting a reset asserts it in its own domain IMMEDIATELY (before the
//      next clock edge) and does not disturb the other resets: the TX and RX
//      GMII-domain resets stay independent, as in the original core
//   C. a reset pulse much shorter than a clock still resets (asynchronous
//      assert), then releases cleanly two clocks later
//   D. AXI4-Lite: a register written after reset reads back, is cleared by a
//      s_axi_lite_resetn pulse, and s_axi_awready is low while that reset is
//      asserted
//
// axis_clk (7 ns) and gtx_clk (8 ns) are deliberately asynchronous.

`timescale 1ns/1ps

module tb_mac_reset_reclock;

  logic axis_clk = 0;
  logic gtx_clk  = 0;
  always #3.5 axis_clk = ~axis_clk;
  always #4   gtx_clk  = ~gtx_clk;

  logic axi_txd_arstn = 0, axi_txc_arstn = 0, axi_rxd_arstn = 0, axi_rxs_arstn = 0;
  logic s_axi_lite_resetn = 0;

  logic [31:0] s_axis_txd_tdata = 0;
  logic [3:0]  s_axis_txd_tkeep = 4'hf;
  logic        s_axis_txd_tlast = 0, s_axis_txd_tvalid = 0, s_axis_txd_tready;
  logic        s_axis_txc_tvalid = 0, s_axis_txc_tready, s_axis_txc_tlast = 1;

  logic [17:0] s_axi_awaddr = 0;
  logic        s_axi_awvalid = 0, s_axi_awready;
  logic [31:0] s_axi_wdata = 0;
  logic [3:0]  s_axi_wstrb = 4'hf;
  logic        s_axi_wvalid = 0, s_axi_wready;
  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid, s_axi_bready = 1;
  logic [17:0] s_axi_araddr = 0;
  logic        s_axi_arvalid = 0, s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid, s_axi_rready = 1;

  open_eth_mac_1g_switch dut (
    .axis_clk (axis_clk), .s_axi_lite_clk (axis_clk), .gtx_clk (gtx_clk), .clk_en (1'b1),
    .axi_txd_arstn (axi_txd_arstn), .axi_txc_arstn (axi_txc_arstn),
    .axi_rxd_arstn (axi_rxd_arstn), .axi_rxs_arstn (axi_rxs_arstn),
    .s_axi_lite_resetn (s_axi_lite_resetn),
    .s_axis_txd_tdata (s_axis_txd_tdata), .s_axis_txd_tkeep (s_axis_txd_tkeep),
    .s_axis_txd_tlast (s_axis_txd_tlast), .s_axis_txd_tvalid (s_axis_txd_tvalid),
    .s_axis_txd_tready (s_axis_txd_tready),
    .s_axis_txc_tdata (32'h0), .s_axis_txc_tkeep (4'hf), .s_axis_txc_tlast (s_axis_txc_tlast),
    .s_axis_txc_tvalid (s_axis_txc_tvalid), .s_axis_txc_tready (s_axis_txc_tready),
    .m_axis_rxd_tdata (), .m_axis_rxd_tkeep (), .m_axis_rxd_tlast (), .m_axis_rxd_tvalid (),
    .m_axis_rxd_tready (1'b1),
    .m_axis_rxs_tdata (), .m_axis_rxs_tkeep (), .m_axis_rxs_tlast (), .m_axis_rxs_tvalid (),
    .m_axis_rxs_tready (1'b1),
    .s_axi_awaddr (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
    .s_axi_wdata (s_axi_wdata), .s_axi_wstrb (s_axi_wstrb), .s_axi_wvalid (s_axi_wvalid),
    .s_axi_wready (s_axi_wready), .s_axi_bresp (s_axi_bresp), .s_axi_bvalid (s_axi_bvalid),
    .s_axi_bready (s_axi_bready), .s_axi_araddr (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready), .s_axi_rdata (s_axi_rdata), .s_axi_rresp (s_axi_rresp),
    .s_axi_rvalid (s_axi_rvalid), .s_axi_rready (s_axi_rready),
    .gmii_rxd (8'h00), .gmii_rx_dv (1'b0), .gmii_rx_er (1'b0),
    .gmii_txd (), .gmii_tx_en (), .gmii_tx_er (),
    .interrupt (), .mac_irq ()
  );

  int errors = 0;

  task automatic axi_write(input logic [17:0] addr, input logic [31:0] data);
    @(posedge axis_clk);
    s_axi_awaddr <= addr; s_axi_awvalid <= 1;
    s_axi_wdata  <= data; s_axi_wvalid  <= 1;
    while (!(s_axi_awready && s_axi_wready)) @(posedge axis_clk);
    @(posedge axis_clk);
    s_axi_awvalid <= 0; s_axi_wvalid <= 0;
    while (!s_axi_bvalid) @(posedge axis_clk);
    @(posedge axis_clk);
  endtask

  task automatic axi_read(input logic [17:0] addr, output logic [31:0] data);
    @(posedge axis_clk);
    s_axi_araddr <= addr; s_axi_arvalid <= 1;
    while (!s_axi_arready) @(posedge axis_clk);
    @(posedge axis_clk);
    s_axi_arvalid <= 0;
    while (!s_axi_rvalid) @(posedge axis_clk);
    data = s_axi_rdata;
    @(posedge axis_clk);
  endtask

  int n;

  initial begin
    logic [31:0] rd;
    int c_lite, c_axis, c_gtx_tx, c_gtx_rx;

    repeat (5) @(posedge axis_clk);

    // ---- A: everything in reset; then release off any clock edge ----
    if (dut.lite_resetn !== 1'b0 || dut.axis_txd_resetn !== 1'b0 || dut.axis_txc_resetn !== 1'b0 ||
        dut.axis_rxd_resetn !== 1'b0 || dut.axis_rxs_resetn !== 1'b0 ||
        dut.gtx_tx_resetn !== 1'b0 || dut.gtx_rx_resetn !== 1'b0) begin
      $display("FAIL: testA an internal reset is not asserted while all inputs are low");
      errors++;
    end
    #1.3;
    {axi_txd_arstn, axi_txc_arstn, axi_rxd_arstn, axi_rxs_arstn, s_axi_lite_resetn} = '1;
    c_lite = -1; c_axis = -1; c_gtx_tx = -1; c_gtx_rx = -1;
    for (int i = 1; i <= 30; i++) begin
      @(posedge axis_clk);
      if (c_lite < 0 && dut.lite_resetn) c_lite = i;
      if (c_axis < 0 && dut.axis_txd_resetn && dut.axis_txc_resetn && dut.axis_rxd_resetn && dut.axis_rxs_resetn) c_axis = i;
      if (c_gtx_tx < 0 && dut.gtx_tx_resetn) c_gtx_tx = i;
      if (c_gtx_rx < 0 && dut.gtx_rx_resetn) c_gtx_rx = i;
    end
    if (c_lite < 1 || c_lite > 3 || c_axis < 1 || c_axis > 3) begin
      $display("FAIL: testA 150 MHz-domain resets released after lite=%0d axis=%0d axis_clk cycles (expected 1..3)", c_lite, c_axis);
      errors++;
    end else if (c_gtx_tx < c_axis || c_gtx_tx > 12 || c_gtx_rx < c_axis || c_gtx_rx > 12) begin
      $display("FAIL: testA GMII-domain resets released after tx=%0d rx=%0d axis_clk cycles (axis released at %0d)", c_gtx_tx, c_gtx_rx, c_axis);
      errors++;
    end else begin
      $display("PASS: testA resets low at power-up; released in lite=%0d axis=%0d gtx_tx=%0d gtx_rx=%0d axis_clk cycles after the input", c_lite, c_axis, c_gtx_tx, c_gtx_rx);
    end

    // ---- B: assertion is immediate in the owning domain; independence ----
    repeat (10) @(posedge axis_clk);
    #1.7; // mid-cycle
    axi_txd_arstn = 0;
    #0.2;
    if (dut.axis_txd_resetn !== 1'b0 || s_axis_txd_tready !== 1'b0) begin
      $display("FAIL: testB axi_txd_arstn did not assert axis_txd_resetn / drop s_axis_txd_tready before the next clock edge");
      errors++;
    end else $display("PASS: testB axi_txd_arstn asserts the axis-domain reset immediately (s_axis_txd_tready low)");
    repeat (12) @(posedge axis_clk);
    begin
      bit ok = 1'b1;
      if (dut.gtx_tx_resetn !== 1'b0) begin $display("FAIL: testB gtx_tx_resetn never asserted"); ok = 1'b0; end
      if (dut.gtx_rx_resetn !== 1'b1 || dut.axis_rxd_resetn !== 1'b1 || dut.axis_rxs_resetn !== 1'b1 || dut.axis_txc_resetn !== 1'b1) begin
        $display("FAIL: testB resetting TX disturbed the RX / control resets"); ok = 1'b0;
      end
      if (ok) $display("PASS: testB TX reset propagated to the GMII TX domain only; RX and control resets untouched");
      else errors++;
    end
    axi_txd_arstn = 1;
    repeat (12) @(posedge axis_clk);

    axi_rxs_arstn = 0;
    repeat (12) @(posedge axis_clk);
    if (dut.gtx_rx_resetn !== 1'b0 || dut.gtx_tx_resetn !== 1'b1) begin
      $display("FAIL: testB axi_rxs_arstn should reset the GMII RX domain only (rx=%0b tx=%0b)", dut.gtx_rx_resetn, dut.gtx_tx_resetn);
      errors++;
    end else $display("PASS: testB axi_rxs_arstn resets the GMII RX domain only");
    axi_rxs_arstn = 1;
    repeat (12) @(posedge axis_clk);

    #1.1;
    axi_txc_arstn = 0;
    #0.2;
    if (s_axis_txc_tready !== 1'b0) begin
      $display("FAIL: testB axi_txc_arstn did not drop s_axis_txc_tready immediately");
      errors++;
    end else $display("PASS: testB axi_txc_arstn drops s_axis_txc_tready immediately");
    axi_txc_arstn = 1;
    repeat (6) @(posedge axis_clk);

    // ---- C: a sub-clock reset pulse still resets ----
    #0.9;
    axi_rxd_arstn = 0;
    #0.4;  // 0.4 ns << 7 ns clock
    axi_rxd_arstn = 1;
    #0.1;
    if (dut.axis_rxd_resetn !== 1'b0) begin
      $display("FAIL: testC a 0.4 ns reset pulse did not assert axis_rxd_resetn");
      errors++;
    end else begin
      n = 0;
      while (!dut.axis_rxd_resetn && n < 6) begin @(posedge axis_clk); n++; end
      if (n < 1 || n > 3) begin
        $display("FAIL: testC axis_rxd_resetn released after %0d cycles (expected 1..3)", n);
        errors++;
      end else $display("PASS: testC a 0.4 ns reset pulse asserts the reset asynchronously; released cleanly %0d cycles later", n);
    end
    repeat (12) @(posedge axis_clk);

    // ---- D: AXI4-Lite through a lite reset ----
    axi_write(18'h00014, 32'h0000_5a5a);
    axi_read(18'h00014, rd);
    if (rd !== 32'h0000_5a5a) begin
      $display("FAIL: testD register read back %h, expected 5a5a", rd);
      errors++;
    end
    #1.5;
    s_axi_lite_resetn = 0;
    #0.2;
    if (s_axi_awready !== 1'b0) begin
      $display("FAIL: testD s_axi_awready still high while s_axi_lite_resetn is asserted");
      errors++;
    end
    repeat (4) @(posedge axis_clk);
    s_axi_lite_resetn = 1;
    repeat (6) @(posedge axis_clk);
    axi_read(18'h00014, rd);
    if (rd !== 32'h0) begin
      $display("FAIL: testD register not cleared by the lite reset (read %h)", rd);
      errors++;
    end else $display("PASS: testD AXI4-Lite register written, read back, cleared by s_axi_lite_resetn; awready low during reset");

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #200_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
