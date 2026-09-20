// tb_mac_forwarding_top.sv
//
// Self-checking smoke test for mac_forwarding_top.sv: the module joining
// mac_addr_table_top with one mac_addr_resolver per switch port, closing
// the loop between MAC learning/aging and the actual forwarding decision
// (dest_mask_i/dest_mask_valid_i) that ingress_port_wr.sv/cpu_port_top.sv
// consume -- previously built and tested only in isolation from each
// other.
//
// s_axis_tready_i is tied high on every port throughout: this testbench
// exercises the resolver's own address-extraction/lookup/learn logic,
// not backpressure, and permanently-high tready matches ingress_port_wr's
// actual behavior in its S_RECV state (the only state new frame bytes
// are ever streamed in during).
//
//   A. a frame arrives on port 0 with an unlearned destination MAC ->
//      dest_mask_o[0] must show flood (every port except 0), once
//      resolved
//   B. a reverse frame arrives on port 1, whose *source* MAC is testA's
//      destination MAC -> that MAC becomes learned on port 1
//   C. testA's original frame re-sent on port 0 -> dest_mask_o[0] must
//      now show a *targeted* hit (only port 1 set), not flood
//   D. a malformed frame (<12 bytes, ends before both MACs are captured)
//      on port 2 -> dest_mask_o[2] must resolve to 0 (drop) rather than
//      leaving dest_mask_valid_o[2] stuck low forever

`timescale 1ns/1ps

module tb_mac_forwarding_top;
  import buf_mgr_pkg::*;
  import mac_table_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic age_tick_i = 1'b0;
  logic [AGE_W-1:0] default_age_i = 9'd300;

  logic [NUM_PORTS-1:0][15:0] s_axis_tdata;
  logic [NUM_PORTS-1:0][1:0]  s_axis_tkeep;
  logic [NUM_PORTS-1:0]       s_axis_tvalid;
  logic [NUM_PORTS-1:0]       s_axis_tlast;
  logic [NUM_PORTS-1:0]       s_axis_tready;

  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] dest_mask;
  logic [NUM_PORTS-1:0]                dest_mask_valid;

  assign s_axis_tready = {NUM_PORTS{1'b1}}; // see header note

  mac_forwarding_top dut (
    .clk                (clk),
    .rst_n              (rst_n),
    .age_tick_i         (age_tick_i),
    .default_age_i      (default_age_i),
    .s_axis_tdata_i     (s_axis_tdata),
    .s_axis_tkeep_i     (s_axis_tkeep),
    .s_axis_tvalid_i    (s_axis_tvalid),
    .s_axis_tlast_i     (s_axis_tlast),
    .s_axis_tready_i    (s_axis_tready),
    .dest_mask_o        (dest_mask),
    .dest_mask_valid_o  (dest_mask_valid),
    .flush_req_i ('0),
    .flush_busy_o ()
  );

  int errors = 0;

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  localparam logic [47:0] MAC_UNKNOWN_DST = 48'hAA_BB_CC_DD_EE_01;
  localparam logic [47:0] MAC_A           = 48'h00_11_22_33_44_55; // testA's source, testC's dest

  // builds [dest_mac][src_mac][payload...] and streams it into port
  // `port`, packed two bytes per word (tkeep=2'b01 on a trailing odd byte)
  task automatic send_frame(input int port, input logic [47:0] dest_mac,
                             input logic [47:0] src_mac, input int payload_len);
    byte data[];
    int n, i;
    logic [15:0] word;
    logic [1:0]  keep;
    bit          is_last;
    n = 12 + payload_len;
    data = new[n];
    for (i = 0; i < 6; i++) data[i]   = dest_mac[47 - 8*i -: 8];
    for (i = 0; i < 6; i++) data[6+i] = src_mac[47 - 8*i -: 8];
    for (i = 0; i < payload_len; i++) data[12+i] = byte'(i);

    i = 0;
    while (i < n) begin
      if (i + 1 < n) begin
        word = {data[i+1], data[i]}; keep = 2'b11; is_last = (i+2 >= n);
      end else begin
        word = {8'h00, data[i]}; keep = 2'b01; is_last = 1'b1;
      end
      s_axis_tdata[port]  <= word;
      s_axis_tkeep[port]  <= keep;
      s_axis_tvalid[port] <= 1'b1;
      s_axis_tlast[port]  <= is_last;
      @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    s_axis_tvalid[port] <= 1'b0;
    s_axis_tlast[port]  <= 1'b0;
  endtask

  // sends exactly `n` raw bytes (n < 12) with tlast on the last one --
  // a malformed/short frame that ends before both MACs are captured
  task automatic send_short_frame(input int port, input int n);
    byte data[];
    int i;
    logic [15:0] word;
    logic [1:0]  keep;
    bit          is_last;
    data = new[n];
    for (i = 0; i < n; i++) data[i] = byte'(8'hE0 + i);
    i = 0;
    while (i < n) begin
      if (i + 1 < n) begin
        word = {data[i+1], data[i]}; keep = 2'b11; is_last = (i+2 >= n);
      end else begin
        word = {8'h00, data[i]}; keep = 2'b01; is_last = 1'b1;
      end
      s_axis_tdata[port]  <= word;
      s_axis_tkeep[port]  <= keep;
      s_axis_tvalid[port] <= 1'b1;
      s_axis_tlast[port]  <= is_last;
      @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    s_axis_tvalid[port] <= 1'b0;
    s_axis_tlast[port]  <= 1'b0;
  endtask

  task automatic wait_for_mask(input int port, output bit timed_out);
    int timeout;
    timeout = 0;
    timed_out = 1'b0;
    while (!dest_mask_valid[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 2000) timed_out = 1'b1;
    end
  endtask

  initial begin
    s_axis_tdata  = '0;
    s_axis_tkeep  = '0;
    s_axis_tvalid = '0;
    s_axis_tlast  = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    wait_cycles(5);

    // ---- test A: unknown destination on port 0 -> flood ----
    begin
      bit timed_out;
      send_frame(0, MAC_UNKNOWN_DST, MAC_A, 20);
      wait_for_mask(0, timed_out);
      if (timed_out) begin
        $display("FAIL: testA dest_mask_valid[0] never asserted");
        errors++;
      end else if (dest_mask[0] !== (~(NUM_PORTS'(1) << 0))) begin
        $display("FAIL: testA dest_mask[0]=%0b, expected flood (%0b)", dest_mask[0], ~(NUM_PORTS'(1) << 0));
        errors++;
      end else begin
        $display("PASS: testA unknown destination on port 0 floods to every other port");
      end
    end

    wait_cycles(10);

    // ---- test B: reverse frame on port 1 learns MAC_UNKNOWN_DST there ----
    begin
      bit timed_out;
      send_frame(1, MAC_A, MAC_UNKNOWN_DST, 14);
      wait_for_mask(1, timed_out);
      if (timed_out) begin
        $display("FAIL: testB dest_mask_valid[1] never asserted");
        errors++;
      end else begin
        $display("PASS: testB reverse frame on port 1 processed (source MAC now learned there)");
      end
    end

    wait_cycles(10);

    // ---- test C: re-send testA's frame -> now a targeted hit on port 1 ----
    begin
      bit timed_out;
      send_frame(0, MAC_UNKNOWN_DST, MAC_A, 20);
      wait_for_mask(0, timed_out);
      if (timed_out) begin
        $display("FAIL: testC dest_mask_valid[0] never asserted");
        errors++;
      end else if (dest_mask[0] !== (NUM_PORTS'(1) << 1)) begin
        $display("FAIL: testC dest_mask[0]=%0b, expected targeted hit on port 1 only (%0b)", dest_mask[0], NUM_PORTS'(1) << 1);
        errors++;
      end else begin
        $display("PASS: testC destination now known -> targeted forwarding decision (port 1 only), not flood");
      end
    end

    wait_cycles(10);

    // ---- test D: malformed short frame on port 2 -> resolves to drop ----
    begin
      bit timed_out;
      send_short_frame(2, 7); // < 12 bytes: ends before both MACs captured
      wait_for_mask(2, timed_out);
      if (timed_out) begin
        $display("FAIL: testD dest_mask_valid[2] never asserted (port left stalled on a malformed frame)");
        errors++;
      end else if (dest_mask[2] !== '0) begin
        $display("FAIL: testD dest_mask[2]=%0b, expected 0 (drop)", dest_mask[2]);
        errors++;
      end else begin
        $display("PASS: testD malformed short frame on port 2 resolves to drop, no stall");
      end
    end

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
