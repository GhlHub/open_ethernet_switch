// tb_rx_diag.sv
//
// CPU-visible sticky diagnostics (sticky_xdomain.sv + rx_diag_regs.sv) with
// unrelated clocks: an event in a source domain shows up in STATUS, stays set
// across reads, is cleared only by writing 1 to its bit (0 does nothing, other
// bits untouched), and a new event after the clear sets it again.

`timescale 1ns/1ps

module tb_rx_diag;
  logic clk = 0, rxa = 0, rxb = 0;
  always #3.5 clk = ~clk;      // ~143 MHz CPU
  always #4.0 rxa = ~rxa;      // 125 MHz
  always #4.13 rxb = ~rxb;     // slightly different

  logic rst_n = 0;
  logic [7:0] awaddr, araddr; logic awvalid, wvalid, bready, arvalid, rready;
  wire awready, wready, bvalid, arready, rvalid;
  logic [31:0] wdata; wire [31:0] rdata; logic [3:0] wstrb; wire [1:0] bresp, rresp;

  logic evt0, evt1, evt2, evt3;
  wire [3:0] flags, clr;

  sticky_xdomain s0 (.src_clk (rxa), .src_rst_n (rst_n), .event_i (evt0), .dst_clk (clk), .dst_rst_n (rst_n), .clear_i (clr[0]), .flag_o (flags[0]));
  sticky_xdomain s1 (.src_clk (rxb), .src_rst_n (rst_n), .event_i (evt1), .dst_clk (clk), .dst_rst_n (rst_n), .clear_i (clr[1]), .flag_o (flags[1]));
  sticky_xdomain s2 (.src_clk (rxa), .src_rst_n (rst_n), .event_i (evt2), .dst_clk (clk), .dst_rst_n (rst_n), .clear_i (clr[2]), .flag_o (flags[2]));
  sticky_xdomain s3 (.src_clk (rxb), .src_rst_n (rst_n), .event_i (evt3), .dst_clk (clk), .dst_rst_n (rst_n), .clear_i (clr[3]), .flag_o (flags[3]));

  wire [5:0] link_up, link_tog;
  logic flush_busy = 0;
  logic [1:0] phy_link = 2'b00;
  logic [5:0] evt_set = '0;
  wire irq;
  wire [5:0] fwd_en, learn_en;
  logic [2:0] rx_tag = 3'd0;
  logic       rx_tag_valid = 1'b0;
  wire        rx_tag_pop;

  rx_diag_regs dut (
    .clk (clk), .rst_n (rst_n),
    .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .flags_i (flags), .idelay_rdy_i (2'b10), .clear_o (clr),
    .sfp_status_i (16'h0000), .sfp_pcs_status_i (4'b0111), .sfp_force_disable_o (), .sfp_clr_fault_seen_o (),
    .sfp_clr_removed_seen_o (), .sfp_clr_lockout_o (),
    .link_up_o (link_up), .link_flush_tog_o (link_tog), .link_flush_busy_i (flush_busy),
    .phy_link_i (phy_link), .link_event_set_i (evt_set), .link_irq_o (irq),
    .fwd_en_o (fwd_en), .learn_en_o (learn_en),
    .cpu_rx_tag_i (rx_tag), .cpu_rx_tag_valid_i (rx_tag_valid), .cpu_rx_tag_pop_o (rx_tag_pop));


  int errors = 0;
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("FAIL: %s", m); end endtask

  task automatic axi_write(input logic [7:0] a, input logic [31:0] d, input logic [3:0] st);
    @(posedge clk); awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= st; wvalid <= 1; bready <= 1;
    @(posedge clk); while (!awready) @(posedge clk);
    awvalid <= 0; wvalid <= 0;
    while (!bvalid) @(posedge clk);
    @(posedge clk); bready <= 0;
  endtask
  task automatic axi_read(input logic [7:0] a, output logic [31:0] d);
    @(posedge clk); araddr <= a; arvalid <= 1; rready <= 1;
    @(posedge clk); while (!arready) @(posedge clk);
    arvalid <= 0;
    while (!rvalid) @(posedge clk);
    d = rdata; @(posedge clk); rready <= 0;
  endtask
  task automatic pulse(input int which);
    if (which == 0) begin @(posedge rxa); evt0 <= 1; @(posedge rxa); evt0 <= 0; end
    if (which == 1) begin @(posedge rxb); evt1 <= 1; @(posedge rxb); evt1 <= 0; end
    if (which == 2) begin @(posedge rxa); evt2 <= 1; @(posedge rxa); evt2 <= 0; end
    if (which == 3) begin @(posedge rxb); evt3 <= 1; @(posedge rxb); evt3 <= 0; end
  endtask

  logic [31:0] r;
  initial begin
    evt0 = 0; evt1 = 0; evt2 = 0; evt3 = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0; araddr = 0; arvalid = 0; rready = 0;
    repeat (6) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);

    axi_read(8'h00, r); check(r[3:0] === 4'b0000, "clear after reset"); check(r[5:4] === 2'b10, "idelay ready bits read back");

    pulse(1); repeat (20) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0010, $sformatf("bit1 set after event (%b)", r[3:0]));
    repeat (50) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0010, "bit1 stays set");

    pulse(2); pulse(0); repeat (20) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0111, $sformatf("bits 0,1,2 set (%b)", r[3:0]));

    axi_write(8'h00, 32'h0, 4'hF); repeat (30) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0111, "write of 0 clears nothing");

    axi_write(8'h00, 32'h2, 4'h1);                       // clear bit 1 only
    axi_read(8'h00, r); check(r[1] === 1'b0, "bit1 reads clear immediately after its clear");
    repeat (40) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0101, $sformatf("only bit1 cleared (%b)", r[3:0]));

    pulse(1); repeat (30) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0111, "new event after clear sets bit1 again");

    axi_write(8'h00, 32'hF, 4'h1); repeat (60) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b0000, $sformatf("all cleared (%b)", r[3:0]));
    pulse(3); repeat (30) @(posedge clk);
    axi_read(8'h00, r); check(r[3:0] === 4'b1000, "bit3 (other domain) sets");

    axi_read(8'h20, r); check(r === 32'h7, "PCS state is software-readable");
    axi_write(8'h20, 32'hf, 4'hf);
    axi_read(8'h20, r); check(r === 32'h7, "PCS state is read-only");

    // ---- link registers ----
    axi_read(8'h14, r); check(r[5:0] === 6'b100000, $sformatf("link reset state %b (only CPU port up)", r[5:0]));
    axi_write(8'h0C, 32'h0000_0014, 4'h1);           // set ports 2 and 4
    axi_read(8'h14, r); check(r[5:0] === 6'b110100, $sformatf("after set 2,4: %b", r[5:0]));
    check(link_tog === 6'b000000, "set does not toggle the flush request");
    axi_write(8'h0C, 32'h0000_0000, 4'h1);           // writing 0 sets nothing
    axi_read(8'h14, r); check(r[5:0] === 6'b110100, "write of 0 to LINK_SET changes nothing");
    axi_write(8'h10, 32'h0000_0004, 4'h1);           // clear port 2
    axi_read(8'h14, r); check(r[5:0] === 6'b110000, $sformatf("after clr 2: %b", r[5:0]));
    check(link_tog === 6'b000100, "clear toggles port 2's flush request");
    axi_write(8'h10, 32'h0000_0004, 4'h1);           // clear again although already down
    check(link_tog === 6'b000000, "clearing an already-down port toggles again (flush re-run)");
    axi_write(8'h10, 32'h0000_0030, 4'h1);           // clear 4 and 5
    axi_read(8'h14, r); check(r[5:0] === 6'b000000, "ports 4,5 cleared");
    check(link_tog === 6'b110000, "toggles for ports 4,5");
    axi_write(8'h0C, 32'h0000_0001, 4'h1);
    axi_read(8'h14, r); check(r[5:0] === 6'b000001 && link_tog === 6'b110000, "set port 0 leaves other ports and toggles alone");
    flush_busy = 1; phy_link = 2'b10; repeat (6) @(posedge clk);
    axi_read(8'h14, r); check(r[8] === 1'b1 && r[11:10] === 2'b10, $sformatf("status shows flush busy and PHY link (%h)", r));
    flush_busy = 0; phy_link = 2'b00;

    // ---- link events and interrupt ----
    check(irq === 1'b0, "no irq at start");
    @(posedge clk); evt_set <= 6'b001000; @(posedge clk); evt_set <= '0;
    axi_read(8'h18, r); check(r[5:0] === 6'b001000, "event bit 3 set");
    check(irq === 1'b0, "event not enabled -> no irq");
    axi_write(8'h1C, 32'h0000_0008, 4'h1);
    axi_read(8'h1C, r); check(r[5:0] === 6'b001000, "enable readback");
    repeat (2) @(posedge clk); check(irq === 1'b1, "enabled event raises irq");
    axi_write(8'h18, 32'h0000_0008, 4'h1);
    repeat (2) @(posedge clk); check(irq === 1'b0, "clearing the event drops irq");

    // ---- per-port forwarding/learning control ----
    check(fwd_en === 6'b111111 && learn_en === 6'b111111, "FWD_EN/LEARN_EN both default enabled");
    axi_read(8'h48, r); check(r === 32'h0000_0FFF, $sformatf("PORT_CTRL_STATUS at reset = %h, expected FFF", r));

    axi_write(8'h3C, 32'h0000_0004, 4'h1);            // FWD_CLR port 2
    check(fwd_en === 6'b111011, "FWD_CLR disables forwarding on port 2 only");
    check(link_tog === 6'b110100, "FWD_CLR also toggles port 2's flush request (like LINK_CLR)");
    axi_write(8'h3C, 32'h0000_0000, 4'h1);            // write of 0 does nothing
    check(fwd_en === 6'b111011 && link_tog === 6'b110100, "FWD_CLR write of 0 changes nothing");
    axi_write(8'h38, 32'h0000_0004, 4'h1);            // FWD_SET port 2
    check(fwd_en === 6'b111111, "FWD_SET restores forwarding on port 2");

    axi_write(8'h44, 32'h0000_0010, 4'h1);            // LEARN_CLR port 4
    check(learn_en === 6'b101111, "LEARN_CLR disables learning on port 4 only");
    check(link_tog === 6'b100100, "LEARN_CLR also toggles port 4's flush request");
    axi_write(8'h40, 32'h0000_0010, 4'h1);            // LEARN_SET port 4
    check(learn_en === 6'b111111, "LEARN_SET restores learning on port 4");

    axi_read(8'h48, r); check(r === 32'h0000_0FFF, "PORT_CTRL_STATUS back to all-enabled");

    // The retired arm register cannot affect framed CPU traffic.
    axi_write(8'h4C,32'h80000004,4'hF);
    axi_read(8'h4C,r); check(r === 0,"retired CPU override reads zero");
    axi_read(8'h34,r); check(r === 32'd125000000,"fabric frequency is 125 MHz");
    axi_read(8'h54,r); check(r === 32'h43545801,"CPU framed TX ABI 1");

    // ---- CPU RX ingress-port tag ----
    axi_read(8'h50, r); check(r === 32'h0000_0000, "CPU_RX_TAG reads invalid (bit31=0) with nothing pending");
    rx_tag = 3'd3; rx_tag_valid = 1'b1;
    axi_read(8'h50, r); check(r === 32'h8000_0003, $sformatf("CPU_RX_TAG = %h, expected valid + port 3", r));
    begin
      bit saw_pop;
      saw_pop = 1'b0;
      fork
        axi_read(8'h50, r);
        begin
          repeat (10) begin @(posedge clk); if (rx_tag_pop) saw_pop = 1'b1; end
        end
      join
      check(saw_pop, "reading CPU_RX_TAG pulses cpu_rx_tag_pop_o");
    end
    // model the FIFO emptying in response to that pop, same as the real
    // async_fifo in switch_top.sv would the cycle after rd_en_i
    rx_tag_valid = 1'b0;
    axi_read(8'h50, r); check(r[31] === 1'b0, $sformatf("CPU_RX_TAG reads invalid again after the FIFO empties (got %h)", r));

    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
endmodule
