`timescale 1ns/1ps
// Clock correction can insert/delete the two-byte /C1/ prefix. Verify
// negotiation ignores the resulting fragments and accepts intact sets.
module tb_autoneg_clock_correction;
  logic clk = 0, rst_n = 0;
  always #4 clk = ~clk;
  logic [7:0] rxdata = 0;
  logic rxk = 0;
  wire [7:0] txdata;
  wire txk, active, link_up, full_duplex, remote_fault;
  wire [1:0] pause;
  logic ack_seen = 0;
  autoneg_1000base_x #(
    .BREAK_LINK_CYCLES(8), .LINK_TIMER_CYCLES(64), .IDLE_DETECT_CYCLES(64)
  ) dut (
    .clk(clk), .rst_n(rst_n), .rxdata_i(rxdata), .rxcharisk_i(rxk),
    .rxdisperr_i(1'b0), .rxnotintable_i(1'b0), .pcs_sync_ok_i(1'b1),
    .txdata_o(txdata), .txcharisk_o(txk), .an_tx_active_o(active),
    .link_up_o(link_up), .duplex_full_o(full_duplex), .pause_o(pause),
    .remote_fault_o(remote_fault)
  );
  always @(posedge clk)
    if (!rst_n) ack_seen <= 0;
    else if (active && !txk && txdata == 8'h40) ack_seen <= 1;
  task automatic sym(input logic [7:0] data, input logic k = 0);
    @(negedge clk); rxdata = data; rxk = k;
  endtask
  task automatic prefix();
    sym(8'hbc, 1); sym(8'hb5);
  endtask
  task automatic corrected_configs(input logic [7:0] config_hi);
    // Inserted prefix, then an intact /C1/.
    prefix(); prefix(); sym(8'h20); sym(config_hi);
    // Deleted prefix: only the configuration payload remains.
    sym(8'h20); sym(config_hi);
    // Intact /C2/ guarantees normal config windows remain available.
    sym(8'hbc, 1); sym(8'h42); sym(8'h20); sym(config_hi);
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (16) prefix();
    if (ack_seen || link_up) $fatal(1, "Fragments alone negotiated a link");
    repeat (8) begin prefix(); sym(8'h00); sym(8'h00); end
    if (ack_seen || link_up) $fatal(1, "Zero restart configuration accepted as an ability");
    repeat (8) corrected_configs(8'h00);
    if (!ack_seen || link_up) $fatal(1, "Ability exchange failed with correction fragments");
    repeat (16) corrected_configs(8'h40);
    repeat (100) begin sym(8'hbc, 1); sym(8'h50); end
    if (!link_up || !full_duplex || remote_fault || pause != 0)
      $fatal(1, "Negotiation failed with inserted/deleted /C1/ prefixes");
    $display("PASS: fragments alone rejected; intact configs negotiate through inserted/deleted /C1/ prefixes");
    $finish;
  end
  initial begin #100000; $fatal(1, "Timeout"); end
endmodule
