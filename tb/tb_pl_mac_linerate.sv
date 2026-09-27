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

module tb_pl_mac_linerate #(parameter integer RATE = 2);
`ifdef TEST_RGMII_RATES
  localparam integer SLOW=RATE==2 ? 1 : RATE==1 ? 10 : 100;
`else
  localparam integer SLOW=1;
`endif
  logic clk = 0, axis_clk = 0, gtx_clk = 0;
  always #4 clk = ~clk;              // 125 MHz fabric
  always #3.5 axis_clk = ~axis_clk;    // ~142.9 MHz
  always #4.0 gtx_clk = ~gtx_clk;      // 125 MHz
  logic rst_n = 0, axis_rst_n = 0;

  logic inject_bad=0, inject_end_error=0;
  integer end_rx_count;
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
`ifdef TEST_RGMII_RATES
  wire [2:0] mode;
  wire tx_ce, rx_ce;
  wire [7:0] rx_data;
  wire rx_dv, rx_er, overflow;
  wire [3:0] tx_rise, tx_fall;
  wire ctl_rise,ctl_fall,clock_rise,clock_fall;
  logic pin_clk=0;
  logic [3:0] pin_data=0;
  logic pin_ctl=0;
  logic [3:0] fall_data_q=0;
  logic fall_ctl_q=0,fall_clock_q=0;
  // Model pad DDR launches; independently sample actual forwarded-clock edges.
  always @(posedge gtx_clk) begin
    fall_data_q<=tx_fall; fall_ctl_q<=ctl_fall; fall_clock_q<=clock_fall;
    pin_data <= #1 tx_rise; pin_ctl <= #1 ctl_rise; pin_clk <= #1 clock_rise;
  end
  always @(negedge gtx_clk) begin
    pin_data <= #1 fall_data_q; pin_ctl <= #1 fall_ctl_q; pin_clk <= #1 fall_clock_q;
  end
  logic [3:0] rx_rise=0,rx_fall=0;
  logic rx_ctl_rise=0,rx_ctl_fall=0;
  byte wire_frame[$];
  integer wire_index=0, wire_length=0;
  logic wire_half=0;
  logic [3:0] wire_low;
  logic wire_dv;
  function automatic logic [31:0] wire_crc(input logic[31:0] crc,input byte b);
    logic[31:0] c;c=crc ^ {24'b0,b};
    for(int k=0;k<8;k++)c=c[0]?(c>>1)^32'hedb88320:c>>1;
    return c;
  endfunction
  task automatic check_wire();
    logic[31:0] crc;
    if(wire_frame.size())begin
      if(wire_frame.size()!=wire_length+12)$fatal(1,"wire length %0d expected %0d",wire_frame.size(),wire_length+12);
      for(int n=0;n<7;n++)if(wire_frame[n]!==8'h55)$fatal(1,"wire preamble");
      if(wire_frame[7]!==8'hd5)$fatal(1,"wire SFD");
      crc=32'hffffffff;
      for(int n=8;n<wire_frame.size();n++)begin
        crc=wire_crc(crc,wire_frame[n]);
        if(n<wire_length+8 && wire_frame[n]!==pat(wire_index,n-8))$fatal(1,"wire payload");
      end
      if(crc!==32'hdebb20e3)$fatal(1,"wire CRC");
      wire_frame.delete();wire_index++;
    end
  endtask
  realtime last_rise=0;
  always @(posedge pin_clk) begin
    rx_rise<=pin_data; rx_ctl_rise<=pin_ctl;
    if(RATE==2)begin
      wire_low=pin_data;wire_dv=pin_ctl;
      if(!pin_ctl)check_wire();
    end else if(pin_ctl)begin
      if(wire_half)wire_frame.push_back({pin_data,wire_low});
      else wire_low=pin_data;
      wire_half=!wire_half;
    end else begin wire_half=0;check_wire();end
    if (mode[2]===1'b1 && last_rise && $realtime-last_rise != (RATE==2 ? 8 : RATE==1 ? 40 : 400))
      $fatal(1,"wrong forwarded clock period %f",$realtime-last_rise);
    if (mode[2]===1'b1) last_rise=$realtime;
  end
  always @(negedge pin_clk) begin
    rx_fall<=pin_data; rx_ctl_fall<=pin_ctl ^ inject_bad;
    if(RATE==2 && wire_dv)wire_frame.push_back({pin_data,wire_low});
  end
  rgmii_rate_adapter rate (
    .clk(gtx_clk),.rst_n(axis_rst_n),.mode_i(mode),
    .tx_data_i(gmii_txd),.tx_en_i(gmii_tx_en),.tx_er_i(gmii_tx_er),.tx_byte_ce_o(tx_ce),
    .tx_rise_o(tx_rise),.tx_fall_o(tx_fall),.tx_ctl_rise_o(ctl_rise),.tx_ctl_fall_o(ctl_fall),
    .tx_clk_rise_o(clock_rise),.tx_clk_fall_o(clock_fall),
    .rx_clk(pin_clk),.rx_rst_n(axis_rst_n),.rx_rise_i(rx_rise),.rx_fall_i(rx_fall),
    .rx_ctl_rise_i(rx_ctl_rise),.rx_ctl_fall_i(rx_ctl_fall),
    .rx_data_o(rx_data),.rx_dv_o(rx_dv),.rx_er_o(rx_er),.rx_byte_ce_o(rx_ce),.overflow_o(overflow));
  always @(posedge pin_clk) if (overflow) $fatal(1,"RX FIFO overflow");
  pl_gmii_mac_top #(.EXTERNAL_PACING(1)) dut (
    .port_mode_o(mode),.rx_byte_ce_i(rx_ce),.tx_byte_ce_i(tx_ce),
    .gmii_rxd(rx_data),.gmii_rx_dv(rx_dv),.gmii_rx_er(rx_er | (inject_end_error && !rx_dv)),
`else
  pl_gmii_mac_top dut (
    .gmii_rxd (gmii_txd), .gmii_rx_dv (gmii_tx_en), .gmii_rx_er (gmii_tx_er | inject_bad),
`endif
    .stats_request(stats_request),.stats_select(stats_select),.stats_ack(stats_ack),.stats_value(stats_value),
    .clk (clk), .rst_n (rst_n), .axis_clk (axis_clk), .axis_rst_n (axis_rst_n), .gtx_clk (gtx_clk), .clk_en (1'b1),
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

  task automatic axi_check(input logic [17:0] addr, input logic [31:0] expected);
    @(negedge axis_clk); axi_araddr=addr; axi_arvalid=1; axi_rready=1;
    @(posedge axis_clk); while(!axi_arready) @(posedge axis_clk);
    @(negedge axis_clk); axi_arvalid=0;
    while(!axi_rvalid) @(negedge axis_clk);
    if(axi_rdata!==expected || axi_rresp!=0)
      $fatal(1,"MAC register %h got %h expected %h",addr,axi_rdata,expected);
    @(negedge axis_clk); axi_rready=0;
  endtask

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
  always @(posedge gtx_clk)
`ifdef TEST_RGMII_RATES
    if (tx_ce)
`endif
  begin
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
`ifdef TEST_RGMII_RATES
    wire_index=0;wire_length=len;
`endif
    base_count = rx_count;
    want = rx_count + nframes;
    rx_all.delete(); rx_lens.delete();
    frames_on_wire = 0; max_gap = 0; gap_cnt = 0;
    fork
      send_frames(nframes, len);
      begin t = 0; while (rx_count < want && t < 400000*SLOW) begin @(posedge clk); t++; end end
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
`ifdef TEST_RGMII_RATES
    axi_check(18'h00418,32'd4096);
    axi_check(18'h0041c,32'd2);
    axi_write(18'h0041c,32'(RATE));
    axi_check(18'h0041c,32'(RATE));
    axi_write(18'h00418,32'd2048);
    axi_check(18'h00418,32'd2048);
    axi_check(18'h0041c,32'(RATE));
    axi_write(18'h0041c,32'd3); // reserved speed encoding must not change mode
    axi_check(18'h0041c,32'(RATE));
    repeat(100) @(posedge clk);
    axi_write(18'h0041c,32'(RATE|4));
    repeat(100*SLOW) @(posedge clk);
`endif
    repeat (50) @(posedge clk);

    run_case("A 12 x 1518 B", 12, 1518, 16);
    run_case("B 24 x 64 B", 24, 64, 16);
    run_case("C 60 x 100 B", 60, 100, 16);   // many descriptor-ring wraps
    repeat(100) @(posedge gtx_clk);
    stats_check(0,96); stats_check(4,96);
    stats_check(2,12*1518+24*64+60*100); stats_check(6,12*1518+24*64+60*100);
    stats_check(1,0); stats_check(3,0); stats_check(5,0); stats_check(7,0);
    stats_check(0,0); stats_check(2,0);
`ifdef TEST_RGMII_RATES
    wire_index=0;wire_length=64;
`endif
    inject_bad=1;
    send_frames(1,64);
    repeat(2000*SLOW) @(posedge gtx_clk);
    inject_bad=0;
    stats_check(0,0); stats_check(1,1); stats_check(2,0); stats_check(3,64);
    stats_check(4,1); stats_check(6,64); stats_check(1,0); stats_check(3,0);
`ifdef TEST_RGMII_RATES
    // A trailing partial nibble is reported on the explicit end token. Even
    // a preceding valid FCS must not turn that malformed frame into a good RX.
    wire_index=0;wire_length=64;inject_end_error=1;end_rx_count=rx_count;
    send_frames(1,64);
    repeat(2000*SLOW) @(posedge gtx_clk);
    inject_end_error=0;
    if(rx_count!=end_rx_count)$fatal(1,"error end token was admitted to fabric");
    stats_check(0,0);stats_check(1,1);stats_check(2,0);stats_check(3,64);
`endif
    if (errors) $fatal(1,"MAC line rate failures");
    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
  initial begin #40_000_000; $fatal(1,"global timeout (rx_count=%0d)", rx_count); end
endmodule
