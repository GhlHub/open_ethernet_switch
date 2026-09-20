// tb_mdio_controller.sv
//
// Digital loopback test of mdio_controller_sim_model.sv, driven entirely
// through its AXI4-Lite register interface (see that file's/
// mdio_controller.sv's shared header for the register map) rather than
// wiggling open_eth_mdio_master's own signals directly -- this is
// exactly what real firmware would do. The MDIO bit-level protocol
// checks themselves reuse the same technique as the upstream
// open-ethernet-cores project's own tb_vcu108_mdio_master.v /
// tb_open_eth_mdio_master.v (see docs/source-notices.md): capture the
// driven frame on mdc_o edges for a write, and drive a known pattern
// back onto the (now real, bidirectional) mdio_io pin at the expected
// bit positions for a read.
//
//   A. write transaction: AXI-Lite CONFIG/WRITE_DATA/CONTROL sequence
//      -> captured MDIO frame matches ST/OP/PHYAD/REGAD/TA/DATA exactly,
//      STATUS.BUSY/DONE track the transaction, mdio_io released after
//   B. read transaction: a fixed 16-bit pattern driven back on mdio_io
//      at the right bit positions -> READ_DATA register matches,
//      STATUS.ERROR stays clear
//   C. STATUS.DONE is sticky until explicitly cleared (W1C)

`timescale 1ns/1ps

module tb_mdio_controller;

  logic clk = 0;
  always #4 clk = ~clk; // matches s_axi_lite_clk=150MHz-equivalent elsewhere

  logic rst_n = 0;

  logic [7:0]  awaddr, araddr;
  logic         awvalid, wvalid, bready, arvalid, rready;
  logic         awready, wready, bvalid, arready, rvalid;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  wire  mdio_io;
  logic mdc;

  mdio_controller_sim_model dut (
    .s_axi_lite_clk    (clk),
    .s_axi_lite_resetn (rst_n),
    .s_axi_awaddr      (awaddr),
    .s_axi_awvalid     (awvalid),
    .s_axi_awready     (awready),
    .s_axi_wdata       (wdata),
    .s_axi_wstrb       (wstrb),
    .s_axi_wvalid      (wvalid),
    .s_axi_wready      (wready),
    .s_axi_bresp       (bresp),
    .s_axi_bvalid      (bvalid),
    .s_axi_bready      (bready),
    .s_axi_araddr      (araddr),
    .s_axi_arvalid     (arvalid),
    .s_axi_arready     (arready),
    .s_axi_rdata       (rdata),
    .s_axi_rresp       (rresp),
    .s_axi_rvalid      (rvalid),
    .s_axi_rready      (rready),
    .init_go_i         (1'b0),
    .init_done_o       (),
    .init_fail_o       (),
    .phy_link_o        (),
    .phy_link_change_o (),
    .mdio_io           (mdio_io),
    .mdc_o             (mdc)
  );

  int errors;

  task automatic axi_write(input logic [7:0] addr, input logic [31:0] data, input logic [3:0] strb);
    @(posedge clk);
    awaddr  <= addr;
    awvalid <= 1'b1;
    wdata   <= data;
    wstrb   <= strb;
    wvalid  <= 1'b1;
    bready  <= 1'b1;
    @(posedge clk);
    while (!awready) @(posedge clk);
    awvalid <= 1'b0;
    wvalid  <= 1'b0;
    while (!bvalid) @(posedge clk);
    @(posedge clk);
    bready <= 1'b0;
  endtask

  task automatic axi_read(input logic [7:0] addr, output logic [31:0] data);
    @(posedge clk);
    araddr  <= addr;
    arvalid <= 1'b1;
    rready  <= 1'b1;
    @(posedge clk);
    while (!arready) @(posedge clk);
    arvalid <= 1'b0;
    while (!rvalid) @(posedge clk);
    data = rdata;
    @(posedge clk);
    rready <= 1'b0;
  endtask

  // ---- write-transaction frame capture (see header) ----
  logic [63:0] captured_frame;
  always @(posedge mdc) captured_frame <= {captured_frame[62:0], mdio_io};

  // ---- read-transaction PHY response drive (see header) ----
  // phy_response_active must be explicitly enabled only for testB's own
  // transaction: edge_count free-runs on every mdc negedge any time the
  // master is busy (including testA's own write), so without this gate
  // this block would also drive mdio_io during testA once edge_count
  // happened to land in its 47-63 range -- real bus contention against
  // the DUT's own write data, observed as corrupted/X bits in the
  // captured write frame's later positions until this was added.
  logic [6:0] edge_count;
  logic       phy_drive_en;
  logic       phy_response_active;
  localparam logic [15:0] PHY_READ_DATA = 16'ha5c3;
  always @(negedge mdc) if (dut.busy) edge_count <= edge_count + 1'b1;
  assign phy_drive_en = phy_response_active
    && ((edge_count == 47) || (edge_count >= 48 && edge_count <= 63));
  assign mdio_io = phy_drive_en
    ? (edge_count == 47 ? 1'b0 : PHY_READ_DATA[63-edge_count])
    : 1'bz;

  initial begin
    errors = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
    araddr = 0; arvalid = 0; rready = 0;
    phy_response_active = 1'b0;
    edge_count = 0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // clk_divider=0 for fast simulation (default 100 is sized for real
    // hardware -- a full 64-bit frame at that divider takes ~13,000
    // clk cycles, matching the upstream tb_vcu108_mdio_master.v's own
    // choice of clk_divider=0 for its direct-signal-level test)
    axi_write(8'h14, 32'h0000_0000, 4'b0011);

    // ---- test A: write transaction ----
    begin
      logic [31:0] status;
      captured_frame = 0;

      // CONFIG: phy_addr=7 (byte0), reg_addr=4 (byte1), write_not_read=1 (byte2)
      // -- note the 3'd0 gap, not 10'd0: 15+1+3+5+3+5 = 32 bits exactly,
      // matching CONFIG's real bit layout (byte2[0]=write_not_read at
      // bit 16, byte1=reg_addr at bits[12:8], byte0=phy_addr at bits[4:0])
      axi_write(8'h00, {15'd0, 1'b1, 3'd0, 5'd4, 3'd0, 5'd7}, 4'b0111);
      axi_write(8'h04, 32'h0000_1234, 4'b0011); // WRITE_DATA
      axi_write(8'h0C, 32'h0000_0001, 4'b0001); // CONTROL.START

      axi_read(8'h10, status);
      if (!status[0]) begin
        $display("FAIL: testA STATUS.BUSY not observed asserted right after START");
        errors++;
      end

      begin
        int timeout;
        timeout = 0;
        axi_read(8'h10, status);
        while (status[0] && timeout < 200) begin
          axi_read(8'h10, status);
          timeout++;
        end
        if (status[0]) begin
          $display("FAIL: testA STATUS.BUSY never cleared");
          errors++;
        end else if (!status[1]) begin
          $display("FAIL: testA STATUS.DONE not set after completion");
          errors++;
        end else begin
          #1;
          if (captured_frame !== {32'hffff_ffff, 2'b01, 2'b01, 5'd7, 5'd4, 2'b10, 16'h1234}) begin
            $display("FAIL: testA captured frame mismatch: %016x", captured_frame);
            errors++;
          end else if (mdio_io !== 1'bz) begin
            $display("FAIL: testA mdio_io not released after write completed");
            errors++;
          end else begin
            $display("PASS: testA write transaction framed correctly, MDIO released after");
          end
        end
      end

      axi_write(8'h10, 32'h0000_0002, 4'b0001); // W1C DONE
    end

    // ---- test B: read transaction ----
    begin
      logic [31:0] status, read_data_reg;
      edge_count = 0;
      phy_response_active = 1'b1;

      // CONFIG: phy_addr=1, reg_addr=17, write_not_read=0
      axi_write(8'h00, {15'd0, 1'b0, 3'd0, 5'd17, 3'd0, 5'd1}, 4'b0111);
      axi_write(8'h0C, 32'h0000_0001, 4'b0001); // CONTROL.START

      begin
        int timeout;
        logic [31:0] st;
        timeout = 0;
        st = 32'h1;
        while (st[0] && timeout < 200) begin
          axi_read(8'h10, st);
          timeout++;
        end
        status = st;
      end

      if (status[2]) begin
        $display("FAIL: testB unexpected STATUS.ERROR after read transaction");
        errors++;
      end

      axi_read(8'h08, read_data_reg);
      if (read_data_reg[15:0] !== PHY_READ_DATA) begin
        $display("FAIL: testB READ_DATA = %04x, expected %04x", read_data_reg[15:0], PHY_READ_DATA);
        errors++;
      end else begin
        $display("PASS: testB read transaction returned the correct 16-bit value, no error flagged");
      end

      axi_write(8'h10, 32'h0000_0002, 4'b0001); // W1C DONE
    end

    // ---- test C: STATUS.DONE is sticky until cleared ----
    begin
      logic [31:0] status;
      axi_read(8'h10, status);
      if (status[1]) begin
        $display("FAIL: testC STATUS.DONE still set after being cleared in testB");
        errors++;
      end else begin
        $display("PASS: testC STATUS.DONE correctly cleared by W1C, not still latched");
      end
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #1_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
