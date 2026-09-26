// tb_pl_mac_linerate.sv
//
// End-to-end wire-rate check of one PL GMII port: the real
// open_eth_mac_1g_switch plus both width adapters (pl_gmii_mac_top), with the
// GMII transmit pins looped straight back into the GMII receive pins.
// The switch-side egress stream (16-bit, 125 MHz fabric) is driven as fast as
// tready allows; the switch-side ingress stream is consumed as fast as it
// arrives. If either adapter (or the MAC hand-off) moved less than the wire rate,
// the transmit side would show gaps between frames on the GMII pins or the
// receive side would overflow and lose frames.
//   A. 12 back-to-back 1518-byte frames: all arrive intact, and the idle gap
//      between frames on the GMII transmit pins never exceeds 16 clocks
//      (the MAC's own inter-frame gap is 12)
//   B. 24 back-to-back 64-byte frames (worst case for per-frame overheads): all
//      arrive intact and the gaps stay small
//   C. 60 back-to-back 100-byte frames: the MAC's descriptor rings wrap several
//      times (this case exposed the descriptor-full width bug in the MAC fork:
//      unsent transmit descriptors were overwritten once the pointers wrapped)

`timescale 1ns/1ps

module tb_pl_mac_linerate;
  logic clk = 0, axis_clk = 0, gtx_clk = 0;
  always #4 clk = ~clk;              // 125 MHz fabric
  always #3.5 axis_clk = ~axis_clk;    // ~142.9 MHz
  always #4.0 gtx_clk = ~gtx_clk;      // 125 MHz
  logic rst_n = 0, axis_rst_n = 0;

  logic inject_bad=0;
  wire [7:0] gmii_txd; wire gmii_tx_en, gmii_tx_er;

  // switch ingress stream (from MAC) and egress stream (to MAC)
  wire [15:0] in_tdata; wire [1:0] in_tkeep; wire in_tvalid, in_tlast, in_tuser;
  logic in_tready = 1;
  logic [15:0] eg_tdata; logic [1:0] eg_tkeep; logic eg_tvalid, eg_tlast; wire eg_tready;

  logic [17:0] axi_awaddr; logic axi_awvalid, axi_wvalid, axi_bready, axi_arvalid, axi_rready;
  logic [31:0] axi_wdata; logic [3:0] axi_wstrb; logic [17:0] axi_araddr;
  wire axi_awready, axi_wready, axi_bvalid, axi_arready, axi_rvalid; wire [1:0] axi_bresp, axi_rresp; wire [31:0] axi_rdata;

  logic stats_request=0;
  logic [3:0] stats_select=0;
  wire stats_ack;
  wire [31:0] stats_value;
  task automatic stats_check(input integer index, expected);
    @(negedge axis_clk); stats_select=index; stats_request=1;
    wait(stats_ack); #1;
    if (stats_value !== expected) $fatal(1,"MAC stat %0d = %0d expected %0d",index,stats_value,expected);
    @(negedge axis_clk); stats_request=0;
    wait(!stats_ack); repeat(4) @(posedge axis_clk);
  endtask
  pl_gmii_mac_top dut (
    .stats_request(stats_request),.stats_select(stats_select),.stats_ack(stats_ack),.stats_value(stats_value),
    .clk (clk), .rst_n (rst_n), .axis_clk (axis_clk), .axis_rst_n (axis_rst_n), .gtx_clk (gtx_clk), .clk_en (1'b1),
    .gmii_rxd (gmii_txd), .gmii_rx_dv (gmii_tx_en), .gmii_rx_er (gmii_tx_er | inject_bad),      // loopback
    .gmii_txd (gmii_txd), .gmii_tx_en (gmii_tx_en), .gmii_tx_er (gmii_tx_er),
    .m_axis_tdata (in_tdata), .m_axis_tkeep (in_tkeep), .m_axis_tvalid (in_tvalid), .m_axis_tlast (in_tlast),
    .m_axis_tuser (in_tuser), .m_axis_tready (in_tready),
    .s_axis_tdata (eg_tdata), .s_axis_tkeep (eg_tkeep), .s_axis_tvalid (eg_tvalid), .s_axis_tlast (eg_tlast), .s_axis_tready (eg_tready),
    .s_axi_awaddr (axi_awaddr), .s_axi_awvalid (axi_awvalid), .s_axi_awready (axi_awready),
    .s_axi_wdata (axi_wdata), .s_axi_wstrb (axi_wstrb), .s_axi_wvalid (axi_wvalid), .s_axi_wready (axi_wready),
    .s_axi_bresp (axi_bresp), .s_axi_bvalid (axi_bvalid), .s_axi_bready (axi_bready),
    .s_axi_araddr (axi_araddr), .s_axi_arvalid (axi_arvalid), .s_axi_arready (axi_arready),
    .s_axi_rdata (axi_rdata), .s_axi_rresp (axi_rresp), .s_axi_rvalid (axi_rvalid), .s_axi_rready (axi_rready),
    .interrupt (), .mac_irq ());

  int errors = 0;

  task automatic axi_write(input logic [17:0] addr, input logic [31:0] data);
    axi_awaddr <= addr; axi_awvalid <= 1'b1; axi_wdata <= data; axi_wstrb <= 4'hf; axi_wvalid <= 1'b1; axi_bready <= 1'b1;
    @(posedge axis_clk); while (!axi_awready) @(posedge axis_clk);
    axi_awvalid <= 1'b0;
    while (!axi_wready) @(posedge axis_clk);
    axi_wvalid <= 1'b0;
    while (!axi_bvalid) @(posedge axis_clk);
    @(posedge axis_clk);
  endtask

  // ---- measure gaps between frames on the GMII transmit pins ----
  int gap_cnt, max_gap, frames_on_wire, tx_first_cyc, tx_last_cyc, gcyc;
  logic prev_en;
  always @(posedge gtx_clk) begin
    gcyc <= gcyc + 1;
    prev_en <= gmii_tx_en;
    if (gmii_tx_en && !prev_en) begin
      if (frames_on_wire > 0 && gap_cnt > max_gap) max_gap = gap_cnt;
      if (frames_on_wire == 0) tx_first_cyc = gcyc;
      frames_on_wire <= frames_on_wire + 1;
      gap_cnt <= 0;
    end else if (!gmii_tx_en) gap_cnt <= gap_cnt + 1;
    if (gmii_tx_en) tx_last_cyc <= gcyc;
  end

  // ---- capture received frames (fabric ingress stream) ----
  byte cur [$];
  int  rx_count;
  byte rx_all [$];
  int  rx_lens [$];
  always @(posedge clk) if (in_tvalid && in_tready) begin
    cur.push_back(byte'(in_tdata[7:0]));
    if (in_tkeep[1]) cur.push_back(byte'(in_tdata[15:8]));
    if (in_tlast) begin
      for (int i = 0; i < cur.size(); i++) rx_all.push_back(cur[i]);
      rx_lens.push_back(cur.size());
      cur.delete();
      rx_count <= rx_count + 1;
    end
  end

  function automatic byte pat(input int f, input int i);
    return byte'((f * 31 + i * 7 + 3) & 8'hFF);
  endfunction

  // drive the egress stream: every frame back to back, one word per cycle
  task automatic send_frames(input int nframes, input int len);
    for (int f = 0; f < nframes; f++) begin
      for (int i = 0; i < len; i += 2) begin
        eg_tdata  <= {(i + 1 < len) ? pat(f, i + 1) : 8'h00, pat(f, i)};
        eg_tkeep  <= (i + 1 < len) ? 2'b11 : 2'b01;
        eg_tlast  <= (i + 2 >= len);
        eg_tvalid <= 1'b1;
        @(posedge clk);
        while (!eg_tready) @(posedge clk);
      end
    end
    eg_tvalid <= 1'b0; eg_tlast <= 1'b0;
  endtask

  task automatic run_case(input string name, input int nframes, input int len, input int max_gap_allowed);
    int t, pos, want;
    bit ok;
    int base_frames, base_count;
    base_count = rx_count;
    want = rx_count + nframes;
    rx_all.delete(); rx_lens.delete();
    frames_on_wire = 0; max_gap = 0; gap_cnt = 0;
    fork
      send_frames(nframes, len);
      begin t = 0; while (rx_count < want && t < 400000) begin @(posedge clk); t++; end end
    join
    repeat (20) @(posedge clk);
    ok = (rx_lens.size() == nframes);
    if (!ok) begin errors++; $display("FAIL: %s received %0d of %0d frames", name, rx_lens.size(), nframes); end
    else begin
      pos = 0;
      for (int f = 0; f < nframes; f++) begin
        if (rx_lens[f] != len) begin ok = 0; $display("  frame %0d length %0d (expected %0d)", f, rx_lens[f], len); end
        else for (int i = 0; i < len; i++) if (rx_all[pos + i] !== pat(f, i)) begin if (ok) $display("  frame %0d byte %0d = %h expected %h", f, i, rx_all[pos+i], pat(f, i)); ok = 0; end
        pos += rx_lens[f];
      end
      if (!ok) begin errors++; $display("FAIL: %s frame content/length mismatch", name); end
    end
    $display("INFO: %s: %0d frames on the wire, max inter-frame gap %0d GMII clocks", name, frames_on_wire, max_gap);
    if (max_gap > max_gap_allowed) begin
      errors++; $display("FAIL: %s max inter-frame gap %0d > %0d (the switch side is not keeping the MAC fed)", name, max_gap, max_gap_allowed);
    end
    if (ok && max_gap <= max_gap_allowed) $display("PASS: %s", name);
  endtask

  initial begin
    axi_awaddr = 0; axi_awvalid = 0; axi_wdata = 0; axi_wstrb = 0; axi_wvalid = 0; axi_bready = 0;
    axi_araddr = 0; axi_arvalid = 0; axi_rready = 0;
    eg_tdata = 0; eg_tkeep = 0; eg_tvalid = 0; eg_tlast = 0; rx_count = 0; gcyc = 0; gap_cnt = 0; max_gap = 0; frames_on_wire = 0;
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (5) @(posedge axis_clk); axis_rst_n = 1;
    repeat (10) @(posedge axis_clk);
    axi_write(18'h00408, 32'h1000_0000);   // TX enable
    axi_write(18'h00404, 32'h1200_0000);   // RX enable
    repeat (50) @(posedge clk);

    run_case("A 12 x 1518 B", 12, 1518, 16);
    run_case("B 24 x 64 B", 24, 64, 16);
    run_case("C 60 x 100 B", 60, 100, 16);   // many descriptor-ring wraps
    repeat(100) @(posedge gtx_clk);
    stats_check(0,96); stats_check(4,96);
    stats_check(2,12*1518+24*64+60*100); stats_check(6,12*1518+24*64+60*100);
    stats_check(1,0); stats_check(3,0); stats_check(5,0); stats_check(7,0);
    stats_check(0,0); stats_check(2,0);
    inject_bad=1;
    send_frames(1,64);
    repeat(2000) @(posedge gtx_clk);
    inject_bad=0;
    stats_check(0,0); stats_check(1,1); stats_check(2,0); stats_check(3,64);
    stats_check(4,1); stats_check(6,64); stats_check(1,0); stats_check(3,0);
    if (errors) $fatal(1,"MAC line rate failures");
    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
  initial begin #40_000_000; $fatal(1,"global timeout (rx_count=%0d)", rx_count); end
endmodule
