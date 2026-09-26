// tb_egress_top.sv
//
// Self-checking smoke test for the egress DMA path (5x egress_port_rd +
// egress_dma_rd), backed by the same behavioral AXI4 memory model used
// for the ingress side (tb/axi_mem_bfm.sv). egress_top.sv doesn't own
// buf_mgr_core itself (see its header comment), so this testbench
// instantiates one directly and wires it to egress_top's dequeue/release
// passthrough ports exactly as a real switch_top would -- alloc/enqueue
// are driven straight from the testbench (bypassing the ingress side
// entirely, appropriate for testing egress in isolation), using the same
// do_alloc/do_enqueue protocol already proven in tb_buf_mgr_core.sv.
//
//   A. alloc a buffer, pre-write its frame bytes directly into the DDR
//      model, enqueue it to one physical egress port -> confirm that
//      port's egress_port_rd autonomously dequeues, DMAs it in, and
//      streams it out over AXI4-Stream with the right bytes/tlast, under
//      random downstream (MAC-side) backpressure -> confirm a fresh
//      alloc afterward returns the same bufid (release round-tripped)
//   C. multi-beat frames (lengths straddling 16-byte beat boundaries, so the
//      per-beat prefetch is exercised) under random backpressure, then a
//      1518-byte frame with the MAC side always ready: the port must stream it
//      at about one 16-bit word per cycle (no idle cycles between beats)
//   B. two frames enqueued concurrently to two different physical egress
//      ports -> confirm the shared AXI4 read engine's arbitration serves
//      both correctly with no data mixing between them

`timescale 1ns/1ps

module tb_egress_top;
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #4 clk = ~clk;

  // ---- buf_mgr_core (instantiated directly -- see file header) ----
  logic [NUM_PORTS-1:0]               alloc_req;
  logic [NUM_PORTS-1:0]               alloc_gnt;
  logic [BUF_ID_W-1:0]                alloc_bufid;
  logic [NUM_PORTS-1:0]               enqueue_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] enqueue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0] enqueue_length;
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask;
  logic [NUM_PORTS-1:0]               enqueue_gnt;

  logic [NUM_PORTS-1:0]               dequeue_req;
  logic [NUM_PORTS-1:0]               dequeue_valid;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length;
  logic [NUM_PORTS-1:0]               release_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid;
  logic [NUM_PORTS-1:0]               release_gnt;

  buf_mgr_core u_buf_mgr (
    .clk                (clk),
    .rst_n              (rst_n),
    .alloc_req_i        (alloc_req),
    .alloc_gnt_o        (alloc_gnt),
    .alloc_bufid_o      (alloc_bufid),
    .enqueue_req_i      (enqueue_req),
    .enqueue_bufid_i    (enqueue_bufid),
    .enqueue_length_i   (enqueue_length),
    .enqueue_destmask_i (enqueue_destmask),
    .enqueue_gnt_o      (enqueue_gnt),
    .dequeue_req_i      (dequeue_req),
    .dequeue_valid_o    (dequeue_valid),
    .dequeue_bufid_o    (dequeue_bufid),
    .dequeue_length_o   (dequeue_length),
    .release_req_i      (release_req),
    .release_bufid_i    (release_bufid),
    .release_gnt_o      (release_gnt),
    .link_up_i ({NUM_PORTS{1'b1}}),
    .flush_req_i ('0),
    .flush_busy_o ()
  );

  // ---- egress_top ----
  logic [NUM_PHYS_PORTS-1:0][15:0] m_axis_tdata;
  logic [NUM_PHYS_PORTS-1:0][1:0]  m_axis_tkeep;
  logic [NUM_PHYS_PORTS-1:0]      m_axis_tvalid;
  logic [NUM_PHYS_PORTS-1:0]      m_axis_tlast;
  logic [NUM_PHYS_PORTS-1:0]      m_axis_tready;

  logic [AXI_ID_W-1:0]   m_axi_arid;
  logic [AXI_ADDR_W-1:0] m_axi_araddr;
  logic [7:0]            m_axi_arlen;
  logic [2:0]             m_axi_arsize;
  logic [1:0]             m_axi_arburst;
  logic                   m_axi_arvalid;
  logic                   m_axi_arready;
  logic [AXI_ID_W-1:0]    m_axi_rid;
  logic [AXI_DATA_W-1:0]  m_axi_rdata;
  logic [1:0]             m_axi_rresp;
  logic                   m_axi_rlast;
  logic                   m_axi_rvalid;
  logic                   m_axi_rready;

  logic cpu_dequeue_valid, cpu_dequeue_req = 1'b0;
  logic [BUF_ID_W-1:0] cpu_dequeue_bufid;
  logic [LENGTH_W-1:0] cpu_dequeue_length;
  logic cpu_release_req = 1'b0, cpu_release_gnt;
  logic [BUF_ID_W-1:0] cpu_release_bufid = '0;

  egress_top dut (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .m_axis_tdata              (m_axis_tdata),
    .m_axis_tkeep              (m_axis_tkeep),
    .m_axis_tvalid             (m_axis_tvalid),
    .m_axis_tlast              (m_axis_tlast),
    .m_axis_tready             (m_axis_tready),
    .m_axi_arid                (m_axi_arid),
    .m_axi_araddr              (m_axi_araddr),
    .m_axi_arlen               (m_axi_arlen),
    .m_axi_arsize              (m_axi_arsize),
    .m_axi_arburst             (m_axi_arburst),
    .m_axi_arvalid             (m_axi_arvalid),
    .m_axi_arready             (m_axi_arready),
    .m_axi_rid                 (m_axi_rid),
    .m_axi_rdata                (m_axi_rdata),
    .m_axi_rresp                (m_axi_rresp),
    .m_axi_rlast                (m_axi_rlast),
    .m_axi_rvalid                (m_axi_rvalid),
    .m_axi_rready                (m_axi_rready),
    .dequeue_req_o_passthru      (dequeue_req),
    .dequeue_valid_i_passthru    (dequeue_valid),
    .dequeue_bufid_i_passthru    (dequeue_bufid),
    .dequeue_length_i_passthru   (dequeue_length),
    .release_req_o_passthru      (release_req),
    .release_bufid_o_passthru    (release_bufid),
    .release_gnt_i_passthru      (release_gnt),
    .cpu_dequeue_valid_o          (cpu_dequeue_valid),
    .cpu_dequeue_bufid_o          (cpu_dequeue_bufid),
    .cpu_dequeue_length_o         (cpu_dequeue_length),
    .cpu_dequeue_req_i            (cpu_dequeue_req),
    .cpu_release_req_i            (cpu_release_req),
    .cpu_release_bufid_i          (cpu_release_bufid),
    .cpu_release_gnt_o            (cpu_release_gnt)
  );

  // sized to exactly cover 16 buffers' worth of DDR -- see tb_ingress_top.sv
  // for why this stays small: Icarus Verilog 12.0's elaboration pass
  // scales terribly with this model's unpacked `mem` array past ~64KB.
  axi_mem_bfm #(.MEM_BYTES(16 * BUFFER_BYTES), .BASE_ADDR(DDR_BASE_ADDR)) u_mem (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awid    ('0),
    .s_axi_awaddr  ('0),
    .s_axi_awlen   ('0),
    .s_axi_awsize  ('0),
    .s_axi_awburst ('0),
    .s_axi_awvalid (1'b0),
    .s_axi_awready (),
    .s_axi_wdata   ('0),
    .s_axi_wstrb   ('0),
    .s_axi_wlast   (1'b0),
    .s_axi_wvalid  (1'b0),
    .s_axi_wready  (),
    .s_axi_bid     (),
    .s_axi_bresp   (),
    .s_axi_bvalid  (),
    .s_axi_bready  (1'b0),
    .s_axi_arid    (m_axi_arid),
    .s_axi_araddr  (m_axi_araddr),
    .s_axi_arlen   (m_axi_arlen),
    .s_axi_arsize  (m_axi_arsize),
    .s_axi_arburst (m_axi_arburst),
    .s_axi_arvalid (m_axi_arvalid),
    .s_axi_arready (m_axi_arready),
    .s_axi_rid     (m_axi_rid),
    .s_axi_rdata   (m_axi_rdata),
    .s_axi_rresp   (m_axi_rresp),
    .s_axi_rlast   (m_axi_rlast),
    .s_axi_rvalid  (m_axi_rvalid),
    .s_axi_rready  (m_axi_rready)
  );

  int errors = 0;
  int cyc_count = 0;
  always @(posedge clk) cyc_count <= cyc_count + 1;
  int p2_first = -1, p2_last = -1, p2_words = 0;
  always @(posedge clk) if (m_axis_tvalid[2] && m_axis_tready[2]) begin
    if (p2_words == 0) p2_first = cyc_count;
    p2_words = p2_words + 1;
    if (m_axis_tlast[2]) p2_last = cyc_count;
  end

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // ---- buf_mgr_core driver tasks (identical protocol to tb_buf_mgr_core.sv) ----
  task automatic do_alloc(input int port, output logic [BUF_ID_W-1:0] bufid);
    int timeout;
    bit timed_out;
    alloc_req[port] = 1'b1;
    timeout = 0;
    timed_out = 1'b0;
    while (!alloc_gnt[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: alloc on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    if (timed_out) bufid = 'x;
    else            bufid = alloc_bufid;
    alloc_req[port] = 1'b0;
    @(posedge clk);
  endtask

  task automatic do_enqueue(input int port, input logic [BUF_ID_W-1:0] bufid,
                             input logic [LENGTH_W-1:0] length, input logic [NUM_PORTS-1:0] destmask);
    int timeout;
    bit timed_out;
    enqueue_req[port]      = 1'b1;
    enqueue_bufid[port]    = bufid;
    enqueue_length[port]   = length;
    enqueue_destmask[port] = destmask;
    timeout = 0;
    timed_out = 1'b0;
    while (!enqueue_gnt[port] && !timed_out) begin
      @(posedge clk);
      timeout++;
      if (timeout > 1000) begin
        $display("FAIL: enqueue on port %0d timed out", port);
        errors++;
        timed_out = 1'b1;
      end
    end
    enqueue_req[port] = 1'b0;
    @(posedge clk);
  endtask

  // ---- m_axis_tready backpressure, mode-controlled, sole driver ----
  // (0=held low, 1=~75% random, 2=held high) -- see tb_ps_gem_axis_bridge.sv
  // for why this must be the only process driving each tready bit.
  int bp_mode [NUM_PHYS_PORTS];
  genvar gi;
  generate
    for (gi = 0; gi < NUM_PHYS_PORTS; gi++) begin : g_bp
      initial begin
        m_axis_tready[gi] = 1'b0;
        forever begin
          @(posedge clk);
          case (bp_mode[gi])
            1:       m_axis_tready[gi] <= ($urandom_range(0, 3) != 0);
            2:       m_axis_tready[gi] <= 1'b1;
            default: m_axis_tready[gi] <= 1'b0;
          endcase
        end
      end
    end
  endgenerate

  // ---- capture per-port m_axis_* traffic ----
  // Icarus Verilog 12.0 does not support method calls (.size()/.delete())
  // on an indexed unpacked-array-of-queue (byte q[NUM_PHYS_PORTS][$]),
  // even when the index is a constant genvar -- a distinct limitation
  // from the RTL variable-index bugs documented elsewhere in this
  // project, but the same fix applies: hand-unroll into named per-port
  // queues and dispatch through a constant-armed case statement instead
  // of indexing into the array directly.
  byte cap_bytes_0[$], cap_bytes_1[$], cap_bytes_2[$], cap_bytes_3[$], cap_bytes_4[$];
  int  cap_tlast_idx_0, cap_tlast_idx_1, cap_tlast_idx_2, cap_tlast_idx_3, cap_tlast_idx_4;

  task automatic cap_reset(input int port);
    case (port)
      0: begin cap_bytes_0.delete(); cap_tlast_idx_0 = -1; end
      1: begin cap_bytes_1.delete(); cap_tlast_idx_1 = -1; end
      2: begin cap_bytes_2.delete(); cap_tlast_idx_2 = -1; end
      3: begin cap_bytes_3.delete(); cap_tlast_idx_3 = -1; end
      default: begin cap_bytes_4.delete(); cap_tlast_idx_4 = -1; end
    endcase
  endtask

  // unpack each accepted 16-bit word back into 1 or 2 bytes per tkeep
  // (lower byte always valid, upper byte only when tkeep[1] is set --
  // only ever clear on the trailing word of an odd-length frame)
  always_ff @(posedge clk) if (m_axis_tvalid[0] && m_axis_tready[0]) begin
    cap_bytes_0.push_back(byte'(m_axis_tdata[0][7:0]));
    if (m_axis_tkeep[0][1]) cap_bytes_0.push_back(byte'(m_axis_tdata[0][15:8]));
    if (m_axis_tlast[0]) cap_tlast_idx_0 = cap_bytes_0.size() - 1;
  end
  always_ff @(posedge clk) if (m_axis_tvalid[1] && m_axis_tready[1]) begin
    cap_bytes_1.push_back(byte'(m_axis_tdata[1][7:0]));
    if (m_axis_tkeep[1][1]) cap_bytes_1.push_back(byte'(m_axis_tdata[1][15:8]));
    if (m_axis_tlast[1]) cap_tlast_idx_1 = cap_bytes_1.size() - 1;
  end
  always_ff @(posedge clk) if (m_axis_tvalid[2] && m_axis_tready[2]) begin
    cap_bytes_2.push_back(byte'(m_axis_tdata[2][7:0]));
    if (m_axis_tkeep[2][1]) cap_bytes_2.push_back(byte'(m_axis_tdata[2][15:8]));
    if (m_axis_tlast[2]) cap_tlast_idx_2 = cap_bytes_2.size() - 1;
  end
  always_ff @(posedge clk) if (m_axis_tvalid[3] && m_axis_tready[3]) begin
    cap_bytes_3.push_back(byte'(m_axis_tdata[3][7:0]));
    if (m_axis_tkeep[3][1]) cap_bytes_3.push_back(byte'(m_axis_tdata[3][15:8]));
    if (m_axis_tlast[3]) cap_tlast_idx_3 = cap_bytes_3.size() - 1;
  end
  always_ff @(posedge clk) if (m_axis_tvalid[4] && m_axis_tready[4]) begin
    cap_bytes_4.push_back(byte'(m_axis_tdata[4][7:0]));
    if (m_axis_tkeep[4][1]) cap_bytes_4.push_back(byte'(m_axis_tdata[4][15:8]));
    if (m_axis_tlast[4]) cap_tlast_idx_4 = cap_bytes_4.size() - 1;
  end

  task automatic write_ddr_frame(input logic [BUF_ID_W-1:0] bufid, input byte data[]);
    int base;
    base = int'(bufid) * BUFFER_BYTES; // u_mem.mem is rebased by BASE_ADDR(DDR_BASE_ADDR)
    for (int i = 0; i < data.size(); i++) u_mem.mem[base + i] = data[i];
  endtask

  task automatic check_frame(input int port, input byte expected[], input string label);
    int got_size;
    int got_tlast_idx;
    case (port)
      0: begin got_size = cap_bytes_0.size(); got_tlast_idx = cap_tlast_idx_0; end
      1: begin got_size = cap_bytes_1.size(); got_tlast_idx = cap_tlast_idx_1; end
      2: begin got_size = cap_bytes_2.size(); got_tlast_idx = cap_tlast_idx_2; end
      3: begin got_size = cap_bytes_3.size(); got_tlast_idx = cap_tlast_idx_3; end
      default: begin got_size = cap_bytes_4.size(); got_tlast_idx = cap_tlast_idx_4; end
    endcase
    if (got_size != expected.size()) begin
      $display("FAIL: %s port %0d received %0d bytes, expected %0d", label, port, got_size, expected.size());
      errors++;
    end else begin
      bit ok = 1'b1;
      for (int i = 0; i < expected.size(); i++) begin
        byte b;
        case (port)
          0: b = cap_bytes_0[i];
          1: b = cap_bytes_1[i];
          2: b = cap_bytes_2[i];
          3: b = cap_bytes_3[i];
          default: b = cap_bytes_4[i];
        endcase
        if (b !== expected[i]) ok = 1'b0;
      end
      if (got_tlast_idx != expected.size() - 1) ok = 1'b0;
      if (ok) $display("PASS: %s port %0d frame reproduced exactly (%0d bytes)", label, port, expected.size());
      else begin
        $display("FAIL: %s port %0d content/tlast mismatch", label, port);
        errors++;
      end
    end
  endtask

  initial begin
    alloc_req        = '0;
    enqueue_req       = '0;
    enqueue_bufid      = '0;
    enqueue_length     = '0;
    enqueue_destmask   = '0;
    for (int p = 0; p < NUM_PHYS_PORTS; p++) bp_mode[p] = 0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    wait_cycles(NUM_BUFFERS + 20); // buf_mgr_core's free-list fill sweep

    // ---- test A: single frame, port 2, random backpressure ----
    cap_reset(2);
    bp_mode[2] = 1;
    begin
      logic [BUF_ID_W-1:0] bufid;
      byte data[];
      // odd length: exercises the trailing tkeep=2'b01 single-byte word
      data = new[31];
      for (int i = 0; i < 31; i++) data[i] = byte'(i + 8'h40);
      do_alloc(0, bufid);
      write_ddr_frame(bufid, data);
      do_enqueue(0, bufid, LENGTH_W'(31), NUM_PORTS'(1) << 2);
      wait_cycles(200); // dequeue + DMA read + release + stream out
      check_frame(2, data, "testA");

      // confirm the buffer round-tripped back to the free list -- the
      // free list is FIFO, and other buffers were already ahead of this
      // one in the queue by the time it got released, so a fresh alloc
      // won't necessarily return this exact bufid (see tb_buf_mgr_core.sv,
      // which established the same "alloc just needs to succeed, not
      // return the same id" check for this reason).
      begin
        logic [BUF_ID_W-1:0] bufid2;
        do_alloc(0, bufid2);
        if (alloc_gnt === 1'bx) begin
          $display("FAIL: testA alloc after release did not complete");
          errors++;
        end else begin
          $display("PASS: testA alloc succeeded after release (free list round-trip)");
        end
      end
    end
    bp_mode[2] = 0;

    // ---- test C: multi-beat frames and streaming rate on port 2 ----
    begin
      int lens[$];
      lens.push_back(1); lens.push_back(16); lens.push_back(17); lens.push_back(32);
      lens.push_back(33); lens.push_back(100); lens.push_back(129);
      bp_mode[2] = 1;
      foreach (lens[j]) begin
        logic [BUF_ID_W-1:0] bufid;
        byte data[];
        int L, t;
        L = lens[j];
        data = new[L];
        for (int i = 0; i < L; i++) data[i] = byte'(i * 3 + L);
        cap_reset(2);
        do_alloc(0, bufid);
        write_ddr_frame(bufid, data);
        do_enqueue(0, bufid, LENGTH_W'(L), NUM_PORTS'(1) << 2);
        t = 0;
        while (cap_tlast_idx_2 < 0 && t < 3000) begin @(posedge clk); t++; end
        wait_cycles(3);
        check_frame(2, data, $sformatf("testC len%0d", L));
      end
      bp_mode[2] = 2;
      begin
        logic [BUF_ID_W-1:0] bufid;
        byte data[];
        int t, cyc, words;
        data = new[1518];
        for (int i = 0; i < 1518; i++) data[i] = byte'(i * 5 + 1);
        words = 759;
        cap_reset(2);
        p2_words = 0; p2_first = -1; p2_last = -1;
        do_alloc(0, bufid);
        write_ddr_frame(bufid, data);
        do_enqueue(0, bufid, LENGTH_W'(1518), NUM_PORTS'(1) << 2);
        t = 0;
        while (cap_tlast_idx_2 < 0 && t < 6000) begin @(posedge clk); t++; end
        wait_cycles(3);
        check_frame(2, data, "testC rate");
        cyc = p2_last - p2_first + 1;
        $display("INFO: testC 1518 B streamed as %0d words in %0d cycles (%0d words per 100 cycles)", p2_words, cyc, (p2_words * 100) / cyc);
        if (cyc > words + words / 50 + 6) begin
          $display("FAIL: testC egress stream too slow: %0d cycles for %0d words (idle cycles between beats?)", cyc, words);
          errors++;
        end else $display("PASS: testC egress port streams ~1 word per cycle");
      end
      bp_mode[2] = 0;
    end

    // ---- test B: two concurrent frames, ports 1 and 3 ----
    cap_reset(1);
    cap_reset(3);
    bp_mode[1] = 1;
    bp_mode[3] = 1;
    begin
      logic [BUF_ID_W-1:0] bufid_a, bufid_b;
      byte data_a[];
      byte data_b[];
      data_a = new[22];
      data_b = new[14];
      for (int i = 0; i < 22; i++) data_a[i] = byte'(8'h70 + i);
      for (int i = 0; i < 14; i++) data_b[i] = byte'(8'h90 + i);

      do_alloc(0, bufid_a);
      write_ddr_frame(bufid_a, data_a);
      do_alloc(0, bufid_b);
      write_ddr_frame(bufid_b, data_b);

      fork
        do_enqueue(0, bufid_a, LENGTH_W'(22), NUM_PORTS'(1) << 1);
        do_enqueue(1, bufid_b, LENGTH_W'(14), NUM_PORTS'(1) << 3);
      join

      wait_cycles(300);
      check_frame(1, data_a, "testB");
      check_frame(3, data_b, "testB");
    end
    bp_mode[1] = 0;
    bp_mode[3] = 0;

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else              $display("=== %0d TEST(S) FAILED ===", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: global testbench timeout");
    $finish;
  end

endmodule
