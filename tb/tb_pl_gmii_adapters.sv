// tb_pl_gmii_adapters.sv
//
// Self-checking loopback test for the two new PL GMII MAC width/CDC
// adapters: switch_egress_to_mac_txd.sv's txd output (32-bit AXI4-
// Stream, axis_clk domain) is wired directly into mac_rxd_to_switch_
// ingress.sv's rxd input -- both are the same 32-bit/tkeep/tvalid/
// tlast/tready shape, so this exercises the full round trip (switch
// 16-bit -> unpack -> CDC -> 32-bit gearbox -> [loopback] -> 32-bit
// unpack -> CDC -> 16-bit pack -> switch 16-bit) through both new
// modules at once, the same strategy used for rtl/common/async_fifo.sv
// and the SFP PCS's standalone loopback test earlier in this project.
// s_axis_txc is serviced (tready held high) but not looped anywhere --
// it carries no content this MAC ever reads, per switch_egress_to_mac_
// txd.sv's header note.
//
//   A. one frame, random backpressure on both switch-side ends -> byte
//      content and tlast position preserved exactly, including the
//      trailing tkeep=2'b01 case (odd total length)
//   B. a second frame immediately after -> confirms both modules' state
//      (the txc/txd sequencer, the rxd byte-drain latch, both packer/
//      unpacker halves) resets cleanly between frames
//   C. a frame long enough to span multiple 32-bit MAC-side beats ->
//      confirms the txd gearbox's full-beat (tkeep=1111) path, not just
//      the short/partial-beat path tests A/B already cover

`timescale 1ns/1ps

module tb_pl_gmii_adapters;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk; // 100 MHz (switch fabric side)

  logic axis_clk = 0;
  logic axis_rst_n = 0;
  always #(10.0/3) axis_clk = ~axis_clk; // 150 MHz-equivalent (MAC side)

  // ---- switch egress source (drives switch_egress_to_mac_txd) ----
  logic [15:0] eg_tdata;
  logic [1:0]  eg_tkeep;
  logic        eg_tvalid;
  logic        eg_tlast;
  logic        eg_tready;

  // ---- txc/txd (switch_egress_to_mac_txd's outputs, looped into
  // mac_rxd_to_switch_ingress's rxd input) ----
  logic        txc_tvalid;
  logic        txc_tlast;
  logic        txc_tready;

  logic [31:0] txd_tdata;
  logic [3:0]  txd_tkeep;
  logic        txd_tlast;
  logic        txd_tvalid;
  logic        txd_tready;

  // ---- switch ingress sink (mac_rxd_to_switch_ingress's output) ----
  logic [15:0] ig_tdata;
  logic [1:0]  ig_tkeep;
  logic        ig_tvalid;
  logic        ig_tlast;
  logic        ig_tuser;
  logic        ig_tready;

  assign txc_tready = 1'b1; // serviced, not looped anywhere

  switch_egress_to_mac_txd u_tx (
    .clk                 (clk),
    .rst_n               (rst_n),
    .axis_clk            (axis_clk),
    .axis_rst_n          (axis_rst_n),
    .s_axis_tdata_i      (eg_tdata),
    .s_axis_tkeep_i      (eg_tkeep),
    .s_axis_tvalid_i     (eg_tvalid),
    .s_axis_tlast_i      (eg_tlast),
    .s_axis_tready_o     (eg_tready),
    .s_axis_txc_tvalid_o (txc_tvalid),
    .s_axis_txc_tlast_o  (txc_tlast),
    .s_axis_txc_tready_i (txc_tready),
    .s_axis_txd_tdata_o  (txd_tdata),
    .s_axis_txd_tkeep_o  (txd_tkeep),
    .s_axis_txd_tlast_o  (txd_tlast),
    .s_axis_txd_tvalid_o (txd_tvalid),
    .s_axis_txd_tready_i (txd_tready)
  );

  mac_rxd_to_switch_ingress u_rx (
    .axis_clk           (axis_clk),
    .axis_rst_n         (axis_rst_n),
    .clk                (clk),
    .rst_n              (rst_n),
    .m_axis_rxd_tdata_i (txd_tdata),
    .m_axis_rxd_tkeep_i (txd_tkeep),
    .m_axis_rxd_tlast_i (txd_tlast),
    .m_axis_rxd_tvalid_i(txd_tvalid),
    .m_axis_rxd_tready_o(txd_tready),
    .s_axis_tdata_o     (ig_tdata),
    .s_axis_tkeep_o     (ig_tkeep),
    .s_axis_tvalid_o    (ig_tvalid),
    .s_axis_tlast_o     (ig_tlast),
    .s_axis_tuser_o     (ig_tuser),
    .s_axis_tready_i    (ig_tready)
  );

  int errors = 0;

  task automatic wait_cycles(input int n); repeat (n) @(posedge clk); endtask

  // ---- drive the switch egress source (clk domain), packed 2 bytes/word,
  // nonblocking throughout, mode-controlled backpressure-side readiness
  // handled separately below ----
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
      eg_tdata  <= word;
      eg_tkeep  <= keep;
      eg_tvalid <= 1'b1;
      eg_tlast  <= is_last;
      @(posedge clk);
      while (!eg_tready) @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    eg_tvalid <= 1'b0;
    eg_tlast  <= 1'b0;
  endtask

  // ---- sole driver of ig_tready, mode-controlled (0=low, 1=~75% random,
  // 2=high) -- same rationale as established elsewhere in this project ----
  int bp_mode = 0;
  initial begin
    ig_tready = 1'b0;
    forever begin
      @(posedge clk);
      case (bp_mode)
        1:       ig_tready <= ($urandom_range(0, 3) != 0);
        2:       ig_tready <= 1'b1;
        default: ig_tready <= 1'b0;
      endcase
    end
  end

  // ---- capture the switch ingress sink ----
  byte cap_bytes[$];
  int  cap_tlast_idx;

  task automatic cap_reset();
    cap_bytes.delete();
    cap_tlast_idx = -1;
  endtask

  always_ff @(posedge clk) begin
    if (ig_tvalid && ig_tready) begin
      cap_bytes.push_back(byte'(ig_tdata[7:0]));
      if (ig_tkeep[1]) cap_bytes.push_back(byte'(ig_tdata[15:8]));
      if (ig_tlast) cap_tlast_idx = cap_bytes.size() - 1;
      if (ig_tuser !== 1'b0) begin
        $display("FAIL: ig_tuser unexpectedly set");
        errors++;
      end
    end
  end

  task automatic run_one_frame(input byte data[], input string label);
    cap_reset();
    drive_egress_frame(data);
    wait_cycles(60); // let the round trip through both CDCs settle
    if (cap_bytes.size() != data.size()) begin
      $display("FAIL: %s received %0d bytes, expected %0d", label, cap_bytes.size(), data.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < data.size(); i++) if (cap_bytes[i] !== data[i]) ok = 1'b0;
      if (cap_tlast_idx != data.size() - 1) ok = 1'b0;
      if (ok) $display("PASS: %s frame reproduced exactly (%0d bytes) through both adapters", label, data.size());
      else begin
        $display("FAIL: %s content/tlast mismatch", label);
        errors++;
      end
    end
  endtask

  initial begin
    eg_tdata  = '0;
    eg_tkeep  = '0;
    eg_tvalid = 1'b0;
    eg_tlast  = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge axis_clk);
    axis_rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---- test A: one frame, random backpressure, odd length ----
    bp_mode = 1;
    begin
      byte data[];
      data = new[27];
      for (int i = 0; i < 27; i++) data[i] = byte'(i + 8'h10);
      run_one_frame(data, "testA");
    end
    bp_mode = 0;

    // ---- test B: a second frame right after, even length ----
    bp_mode = 1;
    begin
      byte data[];
      data = new[14];
      for (int i = 0; i < 14; i++) data[i] = byte'(i + 8'h60);
      run_one_frame(data, "testB");
    end
    bp_mode = 0;

    // ---- test C: a frame spanning multiple full 32-bit MAC-side beats ----
    bp_mode = 2;
    begin
      byte data[];
      data = new[100];
      for (int i = 0; i < 100; i++) data[i] = byte'(i);
      run_one_frame(data, "testC");
    end
    bp_mode = 0;

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
