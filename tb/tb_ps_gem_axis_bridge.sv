// tb_ps_gem_axis_bridge.sv
//
// Self-checking smoke test for ps_gem_axis_bridge.sv (the PS GEM FIFO
// Interface <-> AXI4-Stream shim, UG1085 Ch.34 protocol), now dual-clock:
// gem_clk (125 MHz-equivalent, the GEM side's own required rate) and clk
// (62.5 MHz, the fabric side's 16-bit convention), genuinely different
// clocks to actually exercise the async_fifo-based CDC in each direction.
//
//   A. GEM RX push -> m_axis_* ingress, full-rate GEM writes with random
//      m_axis_tready backpressure -> content/tlast/tuser reproduced
//      exactly, no overflow (the CDC FIFO absorbs the backpressure)
//   B. GEM RX push overflow -> push a frame longer than the CDC FIFO
//      while m_axis_tready is held low throughout -> rx_w_overflow_o
//      is high one cycle after the frame's rx_w_eop (UG1085: no later than
//      that), is low again soon after, the truncated frame comes out closed
//      with tlast+tuser (a bad frame), and the NEXT frame is intact
//   C. GEM RX flush mid-frame -> the partly-pushed frame is closed as a bad
//      frame (tlast+tuser), the rest of it is suppressed, and the next
//      frame (whose SOP byte must survive the discard) is intact
//   D. s_axis_* egress -> GEM TX pull -> content/sop/eop reproduced exactly.
//      The frame is buffered first: pulling while it is still filling
//      genuinely underflows (fill 1 byte/16 ns vs pull up to 1 byte/8 ns),
//      which is what test F covers
//   E. dma_tx_end_tog_i -> dma_tx_status_tog_o ack handshake toggles in
//      response within a bounded number of cycles
//   G/H. line rate: a 1518-byte frame through TX (upstream gap every 8
//      words, GEM reading flat out) and through RX (pushed every GEM cycle,
//      fabric always ready / stalling 1 cycle in 16) -> no underflow /
//      overflow, content intact
//   F. TX underflow: the upstream stalls after the start threshold -> exactly
//      one tx_r_underflow_o, no tx_r_valid/data_rdy while draining, one
//      tx_r_flushed_o pulse, the remainder of that frame is discarded (its
//      eop never delivered), and the next frame is delivered intact with sop
//      on its first byte

`timescale 1ns/1ps

module tb_ps_gem_axis_bridge;

  localparam int RX_FIFO_WORDS = 128; // gem_rx_w_to_axis default (16-bit words)
  localparam int START_WORDS   = 128; // axis_to_gem_tx_r default

  logic clk = 0;
  logic rst_n = 0;
  always #8 clk = ~clk; // 62.5 MHz-equivalent (fabric side)

  logic gem_clk = 0;
  logic gem_rst_n = 0;
  always #4 gem_clk = ~gem_clk; // 125 MHz-equivalent (GEM side)

  // ---- RX (GEM push) side signals, gem_clk domain ----
  logic [7:0]  rx_w_data;
  logic        rx_w_wr;
  logic        rx_w_sop;
  logic        rx_w_eop;
  logic        rx_w_err;
  logic        rx_w_flush;
  logic [44:0] rx_w_status;
  logic        rx_w_overflow;

  // ---- ingress AXI4-Stream master, clk domain, 16-bit ----
  logic [15:0] m_axis_tdata;
  logic [1:0]  m_axis_tkeep;
  logic        m_axis_tvalid;
  logic        m_axis_tlast;
  logic        m_axis_tuser;
  logic        m_axis_tready;
  logic [44:0] rx_w_status_o;

  // ---- egress AXI4-Stream slave, clk domain, 16-bit ----
  logic [15:0] s_axis_tdata;
  logic [1:0]  s_axis_tkeep;
  logic        s_axis_tvalid;
  logic        s_axis_tlast;
  logic        s_axis_tready;

  // ---- TX (GEM pull) side signals, gem_clk domain ----
  logic       tx_r_rd;
  logic       tx_r_data_rdy;
  logic       tx_r_valid;
  logic [7:0] tx_r_data;
  logic       tx_r_sop;
  logic       tx_r_eop;
  logic       tx_r_underflow;
  logic       tx_r_flushed;
  logic       dma_tx_end_tog;
  logic       dma_tx_status_tog;

  ps_gem_axis_bridge dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .gem_rx_clk          (gem_clk),
    .gem_rx_rst_n        (gem_rst_n),
    .gem_tx_clk          (gem_clk),
    .gem_tx_rst_n        (gem_rst_n),
    .rx_w_data_i         (rx_w_data),
    .rx_w_wr_i           (rx_w_wr),
    .rx_w_sop_i          (rx_w_sop),
    .rx_w_eop_i          (rx_w_eop),
    .rx_w_err_i          (rx_w_err),
    .rx_w_flush_i        (rx_w_flush),
    .rx_w_status_i       (rx_w_status),
    .rx_w_overflow_o     (rx_w_overflow),
    .m_axis_tdata        (m_axis_tdata),
    .m_axis_tkeep        (m_axis_tkeep),
    .m_axis_tvalid       (m_axis_tvalid),
    .m_axis_tlast        (m_axis_tlast),
    .m_axis_tuser        (m_axis_tuser),
    .m_axis_tready       (m_axis_tready),
    .rx_w_status_o       (rx_w_status_o),
    .s_axis_tdata        (s_axis_tdata),
    .s_axis_tkeep        (s_axis_tkeep),
    .s_axis_tvalid       (s_axis_tvalid),
    .s_axis_tlast        (s_axis_tlast),
    .s_axis_tready       (s_axis_tready),
    .tx_r_rd_i           (tx_r_rd),
    .tx_r_data_rdy_o     (tx_r_data_rdy),
    .tx_r_valid_o        (tx_r_valid),
    .tx_r_data_o         (tx_r_data),
    .tx_r_sop_o          (tx_r_sop),
    .tx_r_eop_o          (tx_r_eop),
    .tx_r_err_o          (),
    .tx_r_underflow_o    (tx_r_underflow),
    .tx_r_flushed_o      (tx_r_flushed),
    .tx_r_control_o      (),
    .dma_tx_end_tog_i    (dma_tx_end_tog),
    .dma_tx_status_tog_o (dma_tx_status_tog),
    .tx_r_status_i       (4'b0)
  );

  // CDC safety monitor: the TX start-permit counter crosses to the GEM clock
  // as a Gray code, which is only safe if it changes by at most one bit per
  // fabric clock.
  int permit_bad = 0;
  logic [15:0] permit_prev = '0;
  function automatic int pop16(input logic [15:0] v);
    int c = 0;
    for (int b = 0; b < 16; b++) if (v[b] === 1'b1) c++;
    return c;
  endfunction
  always @(posedge clk) begin
    if (rst_n && pop16(16'(dut.u_tx.permit_gray_q) ^ permit_prev) > 1) permit_bad++;
    permit_prev <= 16'(dut.u_tx.permit_gray_q);
  end

  int errors = 0;

  // sole driver of m_axis_tready, mode-controlled from the test sequence
  // (bp_mode: 0=held low, 1=~75% random, 2=held high) -- nonblocking, see
  // the note in the driver tasks below about the race this avoids. Kept
  // as the ONE process driving this signal: a second process blocking-
  // assigning it directly (e.g. to force full-speed draining) would
  // fight this one's nonblocking assignment every cycle.
  int bp_mode = 0;
  initial begin
    m_axis_tready = 1'b0;
    forever begin
      @(posedge clk);
      case (bp_mode)
        1:       m_axis_tready <= ($urandom_range(0, 3) != 0);
        2:       m_axis_tready <= 1'b1;
        default: m_axis_tready <= 1'b0;
      endcase
    end
  end

  // push one frame's bytes into the GEM RX push interface at full rate,
  // gem_clk domain (no backpressure exists on this side per the real
  // protocol)
  task automatic gem_push_frame(input byte data[], input bit bad);
    for (int i = 0; i < data.size(); i++) begin
      rx_w_data <= data[i];
      rx_w_wr   <= 1'b1;
      rx_w_sop  <= (i == 0);
      rx_w_eop  <= (i == data.size()-1);
      rx_w_err  <= (i == data.size()-1) ? bad : 1'b0;
      @(posedge gem_clk);
    end
    rx_w_wr  <= 1'b0;
    rx_w_sop <= 1'b0;
    rx_w_eop <= 1'b0;
    rx_w_err <= 1'b0;
  endtask

  // ---- test A/B/C: capture m_axis_* output, unpacking each accepted
  // 16-bit word back into 1 or 2 bytes per tkeep ----
  byte rxd_bytes[$];
  int  rxd_tlast_idx;
  bit  rxd_tuser_at_tlast;

  task automatic capture_axis_reset();
    rxd_bytes.delete();
    rxd_tlast_idx = -1;
    rxd_tuser_at_tlast = 1'b0;
  endtask

  always_ff @(posedge clk) begin
    if (m_axis_tvalid && m_axis_tready) begin
      rxd_bytes.push_back(byte'(m_axis_tdata[7:0]));
      if (m_axis_tkeep[1]) rxd_bytes.push_back(byte'(m_axis_tdata[15:8]));
      if (m_axis_tlast) begin
        rxd_tlast_idx      = rxd_bytes.size() - 1;
        rxd_tuser_at_tlast = m_axis_tuser;
      end
    end
  end

  // ---- test D/E: fake GEM TX puller, gem_clk domain ----
  byte tx_rxd_bytes[$];
  int  tx_rxd_sop_idx;
  int  tx_rxd_eop_idx;

  task automatic tx_capture_reset();
    tx_rxd_bytes.delete();
    tx_rxd_sop_idx = -1;
    tx_rxd_eop_idx = -1;
  endtask

  always_ff @(posedge gem_clk) begin
    if (tx_r_valid) begin
      if (tx_r_sop) tx_rxd_sop_idx = tx_rxd_bytes.size();
      tx_rxd_bytes.push_back(byte'(tx_r_data));
      if (tx_r_eop) tx_rxd_eop_idx = tx_rxd_bytes.size() - 1;
    end
  end

  // fake GEM: wait for tx_r_data_rdy, then pull `n` bytes with random
  // gaps between tx_r_rd pulses (nonblocking, same race-avoidance
  // reasoning as m_axis_tready above), gem_clk domain
  // Pulls until the capture block (driven purely by the DUT's own
  // tx_r_valid_o/tx_r_eop_o) has seen an eop, rather than counting our
  // own tx_r_rd pulses -- gem_clk runs faster than clk here, so the FIFO
  // can genuinely run dry between fabric-side word arrivals, meaning not
  // every requested pulse completes a transfer. Same fix/reasoning as
  // tb_egress_gem_tx_integration.sv's gem_pull_frame earlier in this
  // project.
  task automatic gem_pull_frame(input int max_cycles);
    int c;
    tx_r_rd <= 1'b0;
    while (!tx_r_data_rdy) @(posedge gem_clk);
    c = 0;
    // a GEM starts reading only while tx_r_data_rdy is high, and keeps
    // reading to the end of a frame it has started (UG1085) -- so no read
    // after the frame's eop, which would (correctly) be an underflow
    while (tx_rxd_eop_idx < 0 && c < max_cycles) begin
      @(posedge gem_clk);
      tx_r_rd <= ($urandom_range(0, 2) != 0) && (tx_r_data_rdy || tx_rxd_sop_idx >= 0) && (tx_rxd_eop_idx < 0) && !(tx_r_valid && tx_r_eop);
      c++;
    end
    @(posedge gem_clk);
    tx_r_rd <= 1'b0;
  endtask

  // RX overflow monitor: was it high the cycle after an rx_w_eop, and how
  // long did it stay high after the last eop
  int  ov_cyc = 0;
  int  last_eop_cyc = -1000;
  bit  ov_seen = 1'b0;
  bit  ov_at_eop_p1 = 1'b0;
  int  ov_max_after_eop = 0;
  always_ff @(posedge gem_clk) begin
    ov_cyc <= ov_cyc + 1;
    if (rx_w_wr && rx_w_eop) last_eop_cyc <= ov_cyc;
    if (rx_w_overflow) begin
      ov_seen <= 1'b1;
      if (ov_cyc == last_eop_cyc + 1) ov_at_eop_p1 <= 1'b1;
      if (ov_cyc - last_eop_cyc > ov_max_after_eop && ov_cyc - last_eop_cyc < 100) ov_max_after_eop <= ov_cyc - last_eop_cyc;
    end
  end
  task automatic ov_monitor_reset();
    ov_seen = 1'b0; ov_at_eop_p1 = 1'b0; ov_max_after_eop = 0;
  endtask

  // TX underflow/flush monitor
  int uf_cnt = 0;
  int fl_cnt = 0;
  int fl_hi_cycles = 0;
  bit proto_bad = 1'b0;
  always_ff @(posedge gem_clk) begin
    if (tx_r_underflow) uf_cnt <= uf_cnt + 1;
    if (tx_r_flushed) begin
      fl_hi_cycles <= fl_hi_cycles + 1;
      if (tx_r_valid || tx_r_data_rdy) proto_bad <= 1'b1;
    end else if (fl_hi_cycles != 0) begin
      fl_cnt <= fl_cnt + 1;
      fl_hi_cycles <= 0;
    end
  end
  task automatic tx_mon_reset();
    uf_cnt = 0; fl_cnt = 0; fl_hi_cycles = 0; proto_bad = 1'b0;
  endtask

  // a GEM that reads every cycle it can, and after tx_r_underflow stops
  // reading until tx_r_flushed has gone high and back low (UG1085)
  task automatic gem_pull_aggressive(input int max_cycles);
    int c;
    bit done;
    tx_r_rd <= 1'b0;
    while (!tx_r_data_rdy) @(posedge gem_clk);
    c = 0; done = 1'b0;
    while (!done && c < max_cycles) begin
      tx_r_rd <= 1'b1;
      @(posedge gem_clk);
      c++;
      if (tx_r_valid && tx_r_eop) begin
        // the frame's last byte was just delivered: a GEM stops here
        tx_r_rd <= 1'b0;
        done = 1'b1;
      end else if (tx_r_underflow) begin
        tx_r_rd <= 1'b0;
        while (!tx_r_flushed && c < max_cycles) begin @(posedge gem_clk); c++; end
        while (tx_r_flushed && c < max_cycles)  begin @(posedge gem_clk); c++; end
        done = 1'b1;
      end
    end
    tx_r_rd <= 1'b0;
    @(posedge gem_clk);
  endtask

  // drive one frame into s_axis_* (egress source), packed two bytes per
  // 16-bit word (tkeep=2'b01 on a trailing single byte), nonblocking
  // throughout -- same race/fix as established for the DMA/buf_mgr
  // testbenches earlier in this project.
  // gap_every > 0: leave s_axis_tvalid low for one cycle after every
  // gap_every words (models egress_port_rd.sv's per-16-byte refill gap).
  // last_flag=0 leaves the frame open (no tlast), for streaming a frame in
  // pieces.
  task automatic drive_axis_frame_ex(input byte data[], input int gap_every, input bit last_flag);
    int n;
    int i;
    int words;
    logic [15:0] word;
    logic [1:0]  keep;
    bit          is_last;
    n = data.size();
    i = 0;
    words = 0;
    while (i < n) begin
      if (i + 1 < n) begin
        word    = {data[i+1], data[i]};
        keep    = 2'b11;
        is_last = (i + 2 >= n) && last_flag;
      end else begin
        word    = {8'h00, data[i]};
        keep    = 2'b01;
        is_last = last_flag;
      end
      s_axis_tdata  <= word;
      s_axis_tkeep  <= keep;
      s_axis_tvalid <= 1'b1;
      s_axis_tlast  <= is_last;
      @(posedge clk);
      while (!s_axis_tready) @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
      words++;
      if (gap_every > 0 && (words % gap_every) == 0) begin
        s_axis_tvalid <= 1'b0;
        @(posedge clk);
      end
    end
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  endtask

  task automatic drive_axis_frame(input byte data[]);
    drive_axis_frame_ex(data, 0, 1'b1);
  endtask

  // slice of a frame (indices [from, to)), no tlast
  task automatic drive_axis_slice(input byte data[], input int from, input int to);
    byte part[];
    part = new[to - from];
    for (int i = from; i < to; i++) part[i - from] = data[i];
    drive_axis_frame_ex(part, 0, 1'b0);
  endtask

  initial begin
    rx_w_data   = '0;
    rx_w_wr     = 1'b0;
    rx_w_sop    = 1'b0;
    rx_w_eop    = 1'b0;
    rx_w_err    = 1'b0;
    rx_w_flush  = 1'b0;
    rx_w_status = '0;
    s_axis_tdata  = '0;
    s_axis_tkeep  = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    tx_r_rd        = 1'b0;
    dma_tx_end_tog = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge gem_clk);
    gem_rst_n = 1'b1;
    // xpm_fifo_async (SYNTHESIS build) reports busy for a while after reset
    // and drops writes meanwhile; the behavioral model does not, so this
    // wait costs nothing there
    repeat (100) @(posedge clk);

    // ---- test A: normal RX push, random downstream backpressure ----
    capture_axis_reset();
    bp_mode = 1;
    begin
      byte data[];
      data = new[40];
      for (int i = 0; i < 40; i++) data[i] = byte'(i + 8'h10);
      gem_push_frame(data, 1'b0);
    end
    repeat (40) @(posedge clk); // let the CDC FIFO + packer drain
    bp_mode = 0;

    if (rxd_bytes.size() != 40) begin
      $display("FAIL: testA received %0d bytes, expected 40", rxd_bytes.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < 40; i++) begin
        if (rxd_bytes[i] !== byte'(i + 8'h10)) ok = 1'b0;
      end
      if (rxd_tlast_idx != 39 || rxd_tuser_at_tlast != 1'b0) ok = 1'b0;
      if (rx_w_overflow !== 1'b0) begin
        $display("FAIL: testA rx_w_overflow_o asserted unexpectedly");
        errors++;
      end
      if (ok) $display("PASS: testA GEM RX push -> m_axis_* reproduced frame exactly under backpressure, no overflow");
      else begin
        $display("FAIL: testA content/tlast/tuser mismatch");
        errors++;
      end
    end

    // ---- test B: RX push overflow (FIFO held full, tready never given) ----
    capture_axis_reset();
    ov_monitor_reset();
    bp_mode = 0; // no draining at all during this push
    begin
      byte data[];
      data = new[2 * RX_FIFO_WORDS + 40];
      for (int i = 0; i < 2 * RX_FIFO_WORDS + 40; i++) data[i] = byte'(i);
      gem_push_frame(data, 1'b0);
    end
    repeat (4) @(posedge gem_clk);
    if (!ov_seen) begin
      $display("FAIL: testB rx_w_overflow_o never asserted after exceeding FIFO_DEPTH");
      errors++;
    end else begin
      $display("PASS: testB rx_w_overflow_o asserted once the elastic FIFO filled");
    end
    if (!ov_at_eop_p1 || ov_max_after_eop > 1) begin
      $display("FAIL: testB overflow timing vs rx_w_eop (high at eop+1: %0b, max cycles after eop: %0d; UG1085: no later than one cycle after)", ov_at_eop_p1, ov_max_after_eop);
      errors++;
    end else begin
      $display("PASS: testB rx_w_overflow_o high at eop+1 and gone by eop+2 (UG1085 timing)");
    end
    if (rx_w_overflow !== 1'b0) begin
      $display("FAIL: testB rx_w_overflow_o still high after the frame ended");
      errors++;
    end
    // drain at full speed; the truncated frame must be closed as a bad one
    bp_mode = 2;
    repeat (2 * RX_FIFO_WORDS + 60) @(posedge clk);
    bp_mode = 0;
    if (rxd_tlast_idx < 0 || rxd_tuser_at_tlast !== 1'b1 || rxd_bytes.size() < 64 || rxd_bytes[rxd_bytes.size()-1] !== 8'h00) begin
      $display("FAIL: testB truncated frame not closed as a bad frame (tlast_idx=%0d tuser=%0b bytes=%0d)", rxd_tlast_idx, rxd_tuser_at_tlast, rxd_bytes.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < rxd_bytes.size()-1; i++) if (rxd_bytes[i] !== byte'(i)) ok = 1'b0;
      if (ok) $display("PASS: testB truncated frame delivered as %0d good bytes + a bad-frame terminator", rxd_bytes.size()-1);
      else begin $display("FAIL: testB truncated frame's bytes are wrong"); errors++; end
    end
    // ...and the next frame must not be glued onto it
    capture_axis_reset();
    bp_mode = 1;
    begin
      byte data[];
      data = new[20];
      for (int i = 0; i < 20; i++) data[i] = byte'(8'hC0 + i);
      gem_push_frame(data, 1'b0);
    end
    repeat (40) @(posedge clk);
    bp_mode = 0;
    begin
      bit ok;
      ok = (rxd_bytes.size() == 20) && (rxd_tlast_idx == 19) && (rxd_tuser_at_tlast === 1'b0);
      for (int i = 0; i < rxd_bytes.size() && i < 20; i++) if (rxd_bytes[i] !== byte'(8'hC0 + i)) ok = 1'b0;
      if (ok) $display("PASS: testB the frame after the overflow is intact (not glued to the truncated one)");
      else begin
        $display("FAIL: testB frame after overflow wrong (bytes=%0d tlast_idx=%0d tuser=%0b)", rxd_bytes.size(), rxd_tlast_idx, rxd_tuser_at_tlast);
        for (int i = 0; i < rxd_bytes.size(); i++) $write("%02h ", rxd_bytes[i]);
        $write("\n");
        errors++;
      end
    end

    // ---- test C: flush mid-frame -> closed as a bad frame, remainder
    // suppressed, next frame (SOP must survive the discard) intact ----
    capture_axis_reset();
    bp_mode = 1;
    fork
      begin
        byte data[];
        data = new[10];
        for (int i = 0; i < 10; i++) data[i] = byte'(8'hA0 + i);
        gem_push_frame(data, 1'b0); // flushed mid-frame below
      end
      begin
        repeat (4) @(posedge gem_clk);
        rx_w_flush <= 1'b1;
        @(posedge gem_clk);
        rx_w_flush <= 1'b0;
      end
    join
    repeat (30) @(posedge clk);
    if (rxd_tlast_idx < 0 || rxd_tuser_at_tlast !== 1'b1 || rxd_bytes.size() > 8 || rxd_bytes[rxd_bytes.size()-1] !== 8'h00) begin
      $display("FAIL: testC flushed frame not closed as a bad frame (tlast_idx=%0d tuser=%0b bytes=%0d)", rxd_tlast_idx, rxd_tuser_at_tlast, rxd_bytes.size());
      errors++;
    end else begin
      $display("PASS: testC flushed frame closed as a bad frame (%0d bytes incl. terminator), remainder suppressed", rxd_bytes.size());
    end
    capture_axis_reset();
    begin
      byte data[];
      data = new[16];
      for (int i = 0; i < 16; i++) data[i] = byte'(8'h30 + i);
      gem_push_frame(data, 1'b0);
    end
    repeat (40) @(posedge clk);
    bp_mode = 0;
    begin
      bit ok;
      ok = (rxd_bytes.size() == 16) && (rxd_tlast_idx == 15) && (rxd_tuser_at_tlast === 1'b0);
      for (int i = 0; i < rxd_bytes.size() && i < 16; i++) if (rxd_bytes[i] !== byte'(8'h30 + i)) ok = 1'b0;
      if (ok) $display("PASS: testC the frame after the flush is intact, including its first (SOP) byte");
      else begin $display("FAIL: testC frame after flush wrong (bytes=%0d first=%0h)", rxd_bytes.size(), rxd_bytes.size() ? rxd_bytes[0] : 8'hxx); errors++; end
    end

    // ---- test D: egress AXI4-Stream -> GEM TX pull ----
    tx_capture_reset();
    begin
      byte data[];
      data = new[18];
      for (int i = 0; i < 18; i++) data[i] = byte'(8'h60 + i);
      drive_axis_frame(data);          // buffer the whole frame first (see header)
      repeat (10) @(posedge gem_clk);
      gem_pull_frame(500);
    end
    repeat (10) @(posedge gem_clk);

    if (tx_rxd_bytes.size() != 18) begin
      $display("FAIL: testD GEM pulled %0d bytes, expected 18", tx_rxd_bytes.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < 18; i++) if (tx_rxd_bytes[i] !== byte'(8'h60 + i)) ok = 1'b0;
      if (tx_rxd_sop_idx != 0 || tx_rxd_eop_idx != 17) ok = 1'b0;
      if (ok) $display("PASS: testD s_axis_* -> GEM TX pull reproduced frame exactly, sop/eop placed correctly");
      else begin
        $display("FAIL: testD content/sop/eop mismatch (sop_idx=%0d eop_idx=%0d)", tx_rxd_sop_idx, tx_rxd_eop_idx);
        errors++;
      end
    end
    if (tx_r_data_rdy !== 1'b0) begin
      $display("FAIL: testD tx_r_data_rdy_o still asserted after the frame finished");
      errors++;
    end

    // ---- test E: dma_tx_end_tog_i -> dma_tx_status_tog_o ack ----
    begin
      bit prev = dma_tx_status_tog;
      int timeout;
      dma_tx_end_tog <= ~dma_tx_end_tog;
      timeout = 0;
      while (dma_tx_status_tog == prev && timeout < 10) begin
        @(posedge gem_clk);
        timeout++;
      end
      if (dma_tx_status_tog == prev) begin
        $display("FAIL: testE dma_tx_status_tog_o never acked dma_tx_end_tog_i");
        errors++;
      end else begin
        $display("PASS: testE dma_tx_status_tog_o acked dma_tx_end_tog_i within %0d cycles", timeout);
      end
    end

    // ---- test F: TX underflow -> flush protocol ----
    // A frame is released to the GEM only after START_WORDS of it are
    // buffered, so rate alone can no longer cause underflow. Stream the
    // first 320 bytes (160 words > START_WORDS, so the GEM starts), let the
    // GEM drain them and hit the empty FIFO, then finish the frame late.
    tx_capture_reset();
    tx_mon_reset();
    begin
      byte data[];
      data = new[400];
      for (int i = 0; i < 400; i++) data[i] = byte'(8'h80 + i);
      fork
        begin
          drive_axis_slice(data, 0, 320);
          repeat (600) @(posedge clk);  // upstream stalls; the GEM runs dry
          begin
            byte tail[];
            tail = new[80];
            for (int i = 0; i < 80; i++) tail[i] = data[320 + i];
            drive_axis_frame(tail);      // remainder, with tlast
          end
        end
        gem_pull_aggressive(4000);
      join
    end
    repeat (200) @(posedge gem_clk); // let the rest of the aborted frame drain
    begin
      bit ok;
      ok = 1'b1;
      if (uf_cnt != 1) begin $display("FAIL: testF expected exactly 1 tx_r_underflow_o, saw %0d", uf_cnt); ok = 1'b0; end
      if (fl_cnt != 1) begin $display("FAIL: testF expected exactly 1 tx_r_flushed_o pulse, saw %0d", fl_cnt); ok = 1'b0; end
      if (proto_bad)   begin $display("FAIL: testF tx_r_valid/tx_r_data_rdy asserted while tx_r_flushed_o was high"); ok = 1'b0; end
      if (tx_rxd_eop_idx != -1 || tx_rxd_bytes.size() < 256 || tx_rxd_bytes.size() > 320) begin
        $display("FAIL: testF aborted frame should deliver the buffered prefix and no eop (bytes=%0d eop_idx=%0d)", tx_rxd_bytes.size(), tx_rxd_eop_idx); ok = 1'b0;
      end
      for (int i = 0; i < tx_rxd_bytes.size(); i++) if (tx_rxd_bytes[i] !== byte'(8'h80 + i)) ok = 1'b0;
      if (tx_r_data_rdy !== 1'b0) begin $display("FAIL: testF tx_r_data_rdy_o high after the aborted frame drained"); ok = 1'b0; end
      if (ok) $display("PASS: testF underflow -> 1 underflow, 1 flushed pulse, remainder of the frame discarded (%0d-byte prefix delivered)", tx_rxd_bytes.size());
      else errors++;
    end
    // the next frame is delivered intact, sop on its first byte
    tx_capture_reset();
    tx_mon_reset();
    begin
      byte data[];
      data = new[12];
      for (int i = 0; i < 12; i++) data[i] = byte'(8'h20 + i);
      drive_axis_frame(data);
      repeat (10) @(posedge gem_clk);
      gem_pull_frame(500);
    end
    repeat (10) @(posedge gem_clk);
    begin
      bit ok;
      ok = (tx_rxd_bytes.size() == 12) && (tx_rxd_sop_idx == 0) && (tx_rxd_eop_idx == 11) && (uf_cnt == 0);
      for (int i = 0; i < tx_rxd_bytes.size() && i < 12; i++) if (tx_rxd_bytes[i] !== byte'(8'h20 + i)) ok = 1'b0;
      if (ok) $display("PASS: testF the frame after the flush is delivered intact with sop on its first byte");
      else begin $display("FAIL: testF frame after flush wrong (bytes=%0d sop_idx=%0d eop_idx=%0d uf=%0d)", tx_rxd_bytes.size(), tx_rxd_sop_idx, tx_rxd_eop_idx, uf_cnt); errors++; end
    end

    // ---- test G: TX at line rate -- a 1518-byte frame, upstream gap every
    // 8 words (egress_port_rd.sv's cadence), GEM reading every cycle it can:
    // no underflow, frame intact ----
    tx_capture_reset();
    tx_mon_reset();
    begin
      byte data[];
      data = new[1518];
      for (int i = 0; i < 1518; i++) data[i] = byte'(i * 7 + 3);
      fork
        drive_axis_frame_ex(data, 8, 1'b1);
        gem_pull_aggressive(20000);
      join
      repeat (20) @(posedge gem_clk);
      begin
        bit ok;
        ok = (tx_rxd_bytes.size() == 1518) && (tx_rxd_sop_idx == 0) && (tx_rxd_eop_idx == 1517) && (uf_cnt == 0) && (fl_cnt == 0);
        for (int i = 0; i < tx_rxd_bytes.size() && i < 1518; i++) if (tx_rxd_bytes[i] !== byte'(i * 7 + 3)) ok = 1'b0;
        if (ok) $display("PASS: testG TX 1518-byte frame at line rate: no underflow, content intact");
        else begin $display("FAIL: testG TX line rate (bytes=%0d uf=%0d fl=%0d eop_idx=%0d)", tx_rxd_bytes.size(), uf_cnt, fl_cnt, tx_rxd_eop_idx); errors++; end
      end
    end

    // ---- test H: RX at line rate -- 1518 bytes pushed every GEM cycle;
    // (a) fabric always ready, (b) fabric stalls 1 cycle in 16 ----
    for (int pass = 0; pass < 2; pass++) begin
      capture_axis_reset();
      ov_monitor_reset();
      bp_mode = 2;
      begin
        byte data[];
        data = new[1518];
        for (int i = 0; i < 1518; i++) data[i] = byte'(i * 5 + pass);
        if (pass == 1) begin
          // periodic stall: toggle bp_mode low for one fabric cycle per 16
          fork
            gem_push_frame(data, 1'b0);
            begin
              for (int k = 0; k < 90; k++) begin
                repeat (15) @(posedge clk);
                bp_mode = 0; @(posedge clk); bp_mode = 2;
              end
            end
          join
        end else begin
          gem_push_frame(data, 1'b0);
        end
        bp_mode = 2;
        repeat (400) @(posedge clk);
        bp_mode = 0;
        begin
          bit ok;
          ok = (rxd_bytes.size() == 1518) && (rxd_tlast_idx == 1517) && (rxd_tuser_at_tlast === 1'b0) && !ov_seen;
          for (int i = 0; i < rxd_bytes.size() && i < 1518; i++) if (rxd_bytes[i] !== byte'(i * 5 + pass)) ok = 1'b0;
          if (ok) $display("PASS: testH RX 1518-byte frame at line rate (%s): no overflow, content intact", pass ? "fabric stalls 1 in 16" : "fabric always ready");
          else begin $display("FAIL: testH RX line rate pass %0d (bytes=%0d tlast_idx=%0d overflow_seen=%0b)", pass, rxd_bytes.size(), rxd_tlast_idx, ov_seen); errors++; end
        end
      end
    end

    if (permit_bad != 0) begin
      $display("FAIL: TX permit Gray counter changed more than one bit at once %0d times", permit_bad);
      errors++;
    end else $display("PASS: TX permit Gray counter changed at most one bit per clock (safe to synchronize)");
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
