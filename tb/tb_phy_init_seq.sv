// tb_phy_init_seq.sv
//
// Checks the DP83867 start-up sequence (phy_init_seq.sv, run through
// mdio_controller_sim_model.sv) against a behavioral MDIO slave that models
// the PHY's Clause 22 registers plus the REGCR/ADDAR indirect (MMD) access
// to the extended register file.
//
//   A. PHY present, strap bit 11 clear: end state has FIFO depth 1, force-link
//      cleared, CFG4[7] cleared, RGMIICTL[1:0] set, RGMIIDCTL = 0x67, every
//      other bit of the touched registers preserved, no other register written
//   B. re-run (go re-asserted) with STRAP_STS1[11] set: PHYCR bit 11 cleared too
//   C. while the sequence runs, AXI STATUS.BUSY reads 1 and an AXI START is ignored
//   D. no PHY at the addressed station (bus pulled high): init_fail, not done
//   E. wrong PHY ID: init_fail

`timescale 1ns/1ps

module mdio_phy_model #(
  parameter logic [4:0] ADDR = 5'd2
) (
  input  logic busy_i,
  input  logic mdc,
  inout  wire  mdio,
  input  logic strap11,
  input  logic [15:0] id2
);
  logic [15:0] regs [0:31];
  logic [15:0] ext  [0:511];
  logic [15:0] ext_addr;
  logic [63:0] frame;
  int          n;
  int          bad_writes;
  int          nwrites;

  wire [1:0] op    = {frame[29], frame[28]};
  wire [4:0] phyad = frame[27:23];
  wire [4:0] regad = frame[22:18];

  function automatic logic [15:0] rd_val(input logic [4:0] r);
    if (r == 5'h0E) rd_val = (regs[5'h0D][15:14] != 0) ? ext[ext_addr[8:0]] : ext_addr;
    else rd_val = regs[r];
  endfunction

  wire is_rd = (n >= 36) && (op == 2'b10) && (phyad == ADDR);
  wire [15:0] rv = rd_val(regad);
  wire drive = is_rd && (n >= 47);
  wire dbit  = (n == 47) ? 1'b0 : rv[63 - n];
  assign mdio = drive ? dbit : 1'bz;

  task automatic reset_regs();
    for (int i = 0; i < 32; i++) regs[i] = 16'h0;
    for (int i = 0; i < 512; i++) ext[i] = 16'h0;
    regs[3] = id2;
    regs[5'h10] = 16'hCC08;
    ext[16'h31] = 16'h00FF;
    ext[16'h32] = 16'h00C0;
    ext[16'h86] = 16'h0067;
    ext[16'h6E] = strap11 ? 16'h0800 : 16'h0000;
    bad_writes = 0;
    nwrites = 0;
  endtask

  initial begin n = 0; ext_addr = 0; reset_regs(); end

  always @(posedge mdc) begin
    if (n < 64) frame[63 - n] <= mdio;
    n <= n + 1;
  end

  always @(negedge busy_i) begin
    if (op == 2'b01 && phyad == ADDR) begin
      case (regad)
        5'h0D: regs[5'h0D] = frame[15:0];
        5'h0E: begin
          if (regs[5'h0D][15:14] == 0) ext_addr = frame[15:0];
          else begin
            ext[ext_addr[8:0]] = frame[15:0];
            nwrites++;
            if (ext_addr != 16'h31 && ext_addr != 16'h32 && ext_addr != 16'h86) bad_writes++;
          end
        end
        5'h10: begin regs[5'h10] = frame[15:0]; nwrites++; end
        default: bad_writes++;
      endcase
    end
    n <= 0;
  end

  // REGCR must always address devad 0x1F
  always @(negedge busy_i) if (op == 2'b01 && phyad == ADDR && regad == 5'h0D
                               && frame[4:0] != 5'h1F) bad_writes++;
endmodule

module tb_phy_init_seq;
  logic clk = 0;
  always #4 clk = ~clk;
  logic rst_n = 0;

  logic [7:0]  awaddr, araddr;
  logic        awvalid, wvalid, bready, arvalid, rready;
  wire         awready, wready, bvalid, arready, rvalid;
  logic [31:0] wdata;
  wire  [31:0] rdata;
  logic [3:0]  wstrb;
  wire  [1:0]  bresp, rresp;

  wire mdio0, mdio1;
  pullup (mdio0);
  pullup (mdio1);
  wire mdc0, mdc1;
  logic go0 = 0, go1 = 0, strap = 0;
  wire done0, fail0, done1, fail1;
  logic [31:0] st;

  mdio_controller_sim_model #(.INIT_PHY_ADDR(5'd2), .INIT_WAIT_CYCLES(20)) dut (
    .s_axi_lite_clk (clk), .s_axi_lite_resetn (rst_n),
    .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .init_go_i (go0), .init_done_o (done0), .init_fail_o (fail0),
    .mdio_io (mdio0), .mdc_o (mdc0));

  mdio_phy_model #(.ADDR(5'd2)) phy0 (.busy_i (dut.busy), .mdc (mdc0), .mdio (mdio0),
                                      .strap11 (strap), .id2 (16'hA231));

  // second instance: id mismatch; AXI unused
  mdio_controller_sim_model #(.INIT_PHY_ADDR(5'd3), .INIT_WAIT_CYCLES(20)) dut1 (
    .s_axi_lite_clk (clk), .s_axi_lite_resetn (rst_n),
    .s_axi_awaddr ('0), .s_axi_awvalid (1'b0), .s_axi_awready (),
    .s_axi_wdata ('0), .s_axi_wstrb ('0), .s_axi_wvalid (1'b0), .s_axi_wready (),
    .s_axi_bresp (), .s_axi_bvalid (), .s_axi_bready (1'b0),
    .s_axi_araddr ('0), .s_axi_arvalid (1'b0), .s_axi_arready (),
    .s_axi_rdata (), .s_axi_rresp (), .s_axi_rvalid (), .s_axi_rready (1'b0),
    .init_go_i (go1), .init_done_o (done1), .init_fail_o (fail1),
    .mdio_io (mdio1), .mdc_o (mdc1));

  mdio_phy_model #(.ADDR(5'd3)) phy1 (.busy_i (dut1.busy), .mdc (mdc1), .mdio (mdio1),
                                      .strap11 (1'b0), .id2 (16'h1234));

  wire mdio2, mdc2, done2, fail2;
  pullup (mdio2);
  logic go2 = 0;
  mdio_controller_sim_model #(.INIT_PHY_ADDR(5'd5), .INIT_WAIT_CYCLES(20)) dut2 (
    .s_axi_lite_clk (clk), .s_axi_lite_resetn (rst_n),
    .s_axi_awaddr ('0), .s_axi_awvalid (1'b0), .s_axi_awready (),
    .s_axi_wdata ('0), .s_axi_wstrb ('0), .s_axi_wvalid (1'b0), .s_axi_wready (),
    .s_axi_bresp (), .s_axi_bvalid (), .s_axi_bready (1'b0),
    .s_axi_araddr ('0), .s_axi_arvalid (1'b0), .s_axi_arready (),
    .s_axi_rdata (), .s_axi_rresp (), .s_axi_rvalid (), .s_axi_rready (1'b0),
    .init_go_i (go2), .init_done_o (done2), .init_fail_o (fail2),
    .mdio_io (mdio2), .mdc_o (mdc2));

  int errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("FAIL: %s", msg); end
  endtask

  task automatic axi_write(input logic [7:0] addr, input logic [31:0] data, input logic [3:0] strb);
    @(posedge clk);
    awaddr <= addr; awvalid <= 1'b1; wdata <= data; wstrb <= strb; wvalid <= 1'b1; bready <= 1'b1;
    @(posedge clk);
    while (!awready) @(posedge clk);
    awvalid <= 1'b0; wvalid <= 1'b0;
    while (!bvalid) @(posedge clk);
    @(posedge clk);
    bready <= 1'b0;
  endtask

  task automatic axi_read(input logic [7:0] addr, output logic [31:0] data);
    @(posedge clk);
    araddr <= addr; arvalid <= 1'b1; rready <= 1'b1;
    @(posedge clk);
    while (!arready) @(posedge clk);
    arvalid <= 1'b0;
    while (!rvalid) @(posedge clk);
    data = rdata;
    @(posedge clk);
    rready <= 1'b0;
  endtask

  task automatic wait_finish(input int timeout_clks);
    int t = 0;
    while (!done0 && !fail0 && t < timeout_clks) begin @(posedge clk); t++; end
    check(t < timeout_clks, "init timed out");
    repeat (4) @(posedge clk);
  endtask

  initial begin
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
    araddr = 0; arvalid = 0; rready = 0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    axi_write(8'h14, 32'd0, 4'b0011);   // fast MDC for simulation

    // ---- A: normal configuration ----
    go0 = 1;
    // ---- C: hold-off while the sequencer owns the master ----
    repeat (100) @(posedge clk);
    axi_read(8'h10, st);
    check(st[0] === 1'b1, "STATUS.BUSY should read 1 while init runs");
    axi_write(8'h04, 32'h0000_BEEF, 4'b0011);
    axi_write(8'h0C, 32'h1, 4'b0001);   // START must be ignored
    wait_finish(3_000_000);
    check(done0 && !fail0, "A: init done");
    check(phy0.regs[5'h10] === 16'h4808, $sformatf("A: PHYCR=%h exp 4808", phy0.regs[5'h10]));
    check(phy0.ext[16'h31] === 16'h007F, $sformatf("A: CFG4=%h exp 007F", phy0.ext[16'h31]));
    check(phy0.ext[16'h32] === 16'h00C3, $sformatf("A: RGMIICTL=%h exp 00C3", phy0.ext[16'h32]));
    check(phy0.ext[16'h86] === 16'h0067, $sformatf("A: RGMIIDCTL=%h exp 0067", phy0.ext[16'h86]));
    check(phy0.bad_writes == 0, "A: unexpected PHY register writes");
    check(phy0.nwrites == 4, $sformatf("A: %0d PHY writes, expected 4", phy0.nwrites));
    axi_read(8'h10, st);
    check(st[2:0] === 3'b000, $sformatf("C: STATUS=%b after init (START ignored, no stray DONE/ERROR)", st[2:0]));

    // ---- B: re-run with STRAP_STS1[11] set ----
    go0 = 0; repeat (10) @(posedge clk);
    strap = 1; phy0.reset_regs();
    go0 = 1; repeat (10) @(posedge clk);
    wait_finish(3_000_000);
    check(done0 && !fail0, "B: init done");
    check(phy0.regs[5'h10] === 16'h4008, $sformatf("B: PHYCR=%h exp 4008", phy0.regs[5'h10]));
    check(phy0.ext[16'h86] === 16'h0067, "B: RGMIIDCTL");

    // ---- D/E: absent PHY, wrong ID ----
    go1 = 1;
    begin
      int t = 0;
      while (!fail1 && !done1 && t < 200000) begin @(posedge clk); t++; end
      check(fail1 && !done1, "E: wrong-ID PHY must fail");
    end
    go2 = 1;
    begin
      int t = 0;
      while (!fail2 && !done2 && t < 200000) begin @(posedge clk); t++; end
      check(fail2 && !done2, "D: absent PHY must fail");
    end
    $display("%s: errors=%0d", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
endmodule
