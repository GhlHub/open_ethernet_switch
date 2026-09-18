// tb_cpu_port_top.sv
//
// Self-checking smoke test for cpu_port_top.sv (ingress_port_wr +
// cpu_dma_wr + egress_port_rd + cpu_dma_rd, all PORT_ID=5), backed by a
// real buf_mgr_core instance (cpu_port_top doesn't own one itself, same
// rationale as tb_egress_top.sv) and the same behavioral AXI4 memory
// model used elsewhere (tb/axi_mem_bfm.sv) -- here wired for BOTH the
// write and read sides at once, since cpu_port_top drives its own
// dedicated AXI4 write AND read masters (unlike tb_ingress_top.sv/
// tb_egress_top.sv, which only ever need one side each).
//
//   A. ingress (CPU TX -> switch): drive a frame into cpu_port_top's
//      s_axis_* input with a forwarding decision targeting physical
//      port 2 -> confirm buf_mgr_core's port-2 queue gets the right
//      {bufid, length}, and the AXI memory actually contains the right
//      bytes at the buffer's DDR address (mirrors tb_ingress_top.sv)
//   B. egress (switch -> CPU RX): alloc a buffer as if a different port
//      (port 0) originated it, pre-write its frame bytes directly into
//      the DDR model, enqueue it destined for the CPU port -> confirm
//      cpu_port_top autonomously dequeues, DMAs it in, and streams it
//      out over m_axis_* with the right bytes/tlast under random
//      downstream (AXI DMA S2MM-side) backpressure, and that a fresh
//      alloc afterward returns the same bufid (release round-tripped)
//      (mirrors tb_egress_top.sv's testA)

`timescale 1ns/1ps

module tb_cpu_port_top;
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

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
    .release_gnt_o      (release_gnt)
  );

  // ---- cpu_port_top ----
  logic [15:0] s_axis_tdata;
  logic [1:0]  s_axis_tkeep;
  logic        s_axis_tvalid;
  logic        s_axis_tlast;
  logic        s_axis_tready;

  logic [15:0] m_axis_tdata;
  logic [1:0]  m_axis_tkeep;
  logic        m_axis_tvalid;
  logic        m_axis_tlast;
  logic        m_axis_tready;

  logic [NUM_PORTS-1:0] dest_mask;
  logic                 dest_mask_valid;

  logic                cpu_alloc_req, cpu_alloc_gnt;
  logic [BUF_ID_W-1:0] cpu_alloc_bufid;
  logic                     cpu_enqueue_req;
  logic [BUF_ID_W-1:0]      cpu_enqueue_bufid;
  logic [LENGTH_W-1:0]      cpu_enqueue_length;
  logic [NUM_PORTS-1:0]     cpu_enqueue_destmask;
  logic                     cpu_enqueue_gnt;

  logic                cpu_dequeue_valid;
  logic [BUF_ID_W-1:0] cpu_dequeue_bufid;
  logic [LENGTH_W-1:0] cpu_dequeue_length;
  logic                cpu_dequeue_req;
  logic                cpu_release_req;
  logic [BUF_ID_W-1:0] cpu_release_bufid;
  logic                cpu_release_gnt;

  logic [AXI_ID_W-1:0]   m_axi_awid;
  logic [AXI_ADDR_W-1:0] m_axi_awaddr;
  logic [7:0]            m_axi_awlen;
  logic [2:0]             m_axi_awsize;
  logic [1:0]             m_axi_awburst;
  logic                   m_axi_awvalid;
  logic                   m_axi_awready;
  logic [AXI_DATA_W-1:0]  m_axi_wdata;
  logic [AXI_STRB_W-1:0]  m_axi_wstrb;
  logic                   m_axi_wlast;
  logic                   m_axi_wvalid;
  logic                   m_axi_wready;
  logic [AXI_ID_W-1:0]    m_axi_bid;
  logic [1:0]             m_axi_bresp;
  logic                   m_axi_bvalid;
  logic                   m_axi_bready;

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

  cpu_port_top dut (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .s_axis_tdata           (s_axis_tdata),
    .s_axis_tkeep           (s_axis_tkeep),
    .s_axis_tvalid          (s_axis_tvalid),
    .s_axis_tlast           (s_axis_tlast),
    .s_axis_tready          (s_axis_tready),
    .m_axis_tdata           (m_axis_tdata),
    .m_axis_tkeep           (m_axis_tkeep),
    .m_axis_tvalid          (m_axis_tvalid),
    .m_axis_tlast           (m_axis_tlast),
    .m_axis_tready          (m_axis_tready),
    .dest_mask_i            (dest_mask),
    .dest_mask_valid_i      (dest_mask_valid),
    .cpu_alloc_req_o        (cpu_alloc_req),
    .cpu_alloc_gnt_i        (cpu_alloc_gnt),
    .cpu_alloc_bufid_i      (cpu_alloc_bufid),
    .cpu_enqueue_req_o      (cpu_enqueue_req),
    .cpu_enqueue_bufid_o    (cpu_enqueue_bufid),
    .cpu_enqueue_length_o   (cpu_enqueue_length),
    .cpu_enqueue_destmask_o (cpu_enqueue_destmask),
    .cpu_enqueue_gnt_i      (cpu_enqueue_gnt),
    .cpu_dequeue_valid_i    (cpu_dequeue_valid),
    .cpu_dequeue_bufid_i    (cpu_dequeue_bufid),
    .cpu_dequeue_length_i   (cpu_dequeue_length),
    .cpu_dequeue_req_o      (cpu_dequeue_req),
    .cpu_release_req_o      (cpu_release_req),
    .cpu_release_bufid_o    (cpu_release_bufid),
    .cpu_release_gnt_i      (cpu_release_gnt),
    .m_axi_awid             (m_axi_awid),
    .m_axi_awaddr           (m_axi_awaddr),
    .m_axi_awlen            (m_axi_awlen),
    .m_axi_awsize           (m_axi_awsize),
    .m_axi_awburst          (m_axi_awburst),
    .m_axi_awvalid          (m_axi_awvalid),
    .m_axi_awready          (m_axi_awready),
    .m_axi_wdata            (m_axi_wdata),
    .m_axi_wstrb            (m_axi_wstrb),
    .m_axi_wlast            (m_axi_wlast),
    .m_axi_wvalid           (m_axi_wvalid),
    .m_axi_wready           (m_axi_wready),
    .m_axi_bid              (m_axi_bid),
    .m_axi_bresp            (m_axi_bresp),
    .m_axi_bvalid           (m_axi_bvalid),
    .m_axi_bready           (m_axi_bready),
    .m_axi_arid             (m_axi_arid),
    .m_axi_araddr           (m_axi_araddr),
    .m_axi_arlen            (m_axi_arlen),
    .m_axi_arsize           (m_axi_arsize),
    .m_axi_arburst          (m_axi_arburst),
    .m_axi_arvalid          (m_axi_arvalid),
    .m_axi_arready          (m_axi_arready),
    .m_axi_rid              (m_axi_rid),
    .m_axi_rdata            (m_axi_rdata),
    .m_axi_rresp            (m_axi_rresp),
    .m_axi_rlast            (m_axi_rlast),
    .m_axi_rvalid           (m_axi_rvalid),
    .m_axi_rready           (m_axi_rready)
  );

  // buf_mgr_core port-5 (CPU) alloc/enqueue/dequeue/release <-> cpu_port_top.
  // Ports 0-4 of these same arrays are driven procedurally below (by
  // do_alloc/do_enqueue and the initial block); a `logic` array cannot
  // mix a continuous `assign` with a procedural driver even on disjoint
  // bit-slices of the same variable, so index 5 is also driven
  // procedurally here (via always_comb) rather than with `assign`.
  assign cpu_alloc_gnt       = alloc_gnt[5];
  assign cpu_alloc_bufid     = alloc_bufid;
  assign cpu_enqueue_gnt     = enqueue_gnt[5];
  assign cpu_dequeue_valid  = dequeue_valid[5];
  assign cpu_dequeue_bufid  = dequeue_bufid[5];
  assign cpu_dequeue_length = dequeue_length[5];
  assign cpu_release_gnt    = release_gnt[5];

  always_comb begin
    alloc_req[5]        = cpu_alloc_req;
    enqueue_req[5]      = cpu_enqueue_req;
    enqueue_bufid[5]    = cpu_enqueue_bufid;
    enqueue_length[5]   = cpu_enqueue_length;
    enqueue_destmask[5] = cpu_enqueue_destmask;
    dequeue_req[5]      = cpu_dequeue_req;
    release_req[5]      = cpu_release_req;
    release_bufid[5]    = cpu_release_bufid;
  end

  // sized to exactly cover 16 buffers' worth of DDR -- see tb_ingress_top.sv
  // for why this stays small (Icarus Verilog elaboration-time scaling)
  axi_mem_bfm #(.MEM_BYTES(16 * BUFFER_BYTES), .BASE_ADDR(DDR_BASE_ADDR)) u_mem (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awid    (m_axi_awid),
    .s_axi_awaddr  (m_axi_awaddr),
    .s_axi_awlen   (m_axi_awlen),
    .s_axi_awsize  (m_axi_awsize),
    .s_axi_awburst (m_axi_awburst),
    .s_axi_awvalid (m_axi_awvalid),
    .s_axi_awready (m_axi_awready),
    .s_axi_wdata   (m_axi_wdata),
    .s_axi_wstrb   (m_axi_wstrb),
    .s_axi_wlast   (m_axi_wlast),
    .s_axi_wvalid  (m_axi_wvalid),
    .s_axi_wready  (m_axi_wready),
    .s_axi_bid     (m_axi_bid),
    .s_axi_bresp   (m_axi_bresp),
    .s_axi_bvalid  (m_axi_bvalid),
    .s_axi_bready  (m_axi_bready),
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

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  // ---- ingress (CPU TX): drive cpu_port_top's s_axis_* input ----
  task automatic send_frame(input byte data[]);
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
      s_axis_tdata  = word;
      s_axis_tkeep  = keep;
      s_axis_tvalid = 1'b1;
      s_axis_tlast  = is_last;
      @(posedge clk);
      while (!s_axis_tready) @(posedge clk);
      i = i + ((keep == 2'b11) ? 2 : 1);
    end
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
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

  task automatic write_ddr_frame(input logic [BUF_ID_W-1:0] bufid, input byte data[]);
    int base;
    base = int'(bufid) * BUFFER_BYTES; // u_mem.mem is rebased by BASE_ADDR(DDR_BASE_ADDR)
    for (int i = 0; i < data.size(); i++) u_mem.mem[base + i] = data[i];
  endtask

  // ---- capture cpu_port_top's m_axis_* (egress, switch -> CPU RX) ----
  byte cap_bytes[$];
  int  cap_tlast_idx;

  task automatic cap_reset();
    cap_bytes.delete();
    cap_tlast_idx = -1;
  endtask

  always_ff @(posedge clk) if (m_axis_tvalid && m_axis_tready) begin
    cap_bytes.push_back(byte'(m_axis_tdata[7:0]));
    if (m_axis_tkeep[1]) cap_bytes.push_back(byte'(m_axis_tdata[15:8]));
    if (m_axis_tlast) cap_tlast_idx = cap_bytes.size() - 1;
  end

  // ---- m_axis_tready backpressure, mode-controlled, sole driver ----
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

  initial begin
    s_axis_tdata  = '0;
    s_axis_tkeep  = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    dest_mask       = '0;
    dest_mask_valid = 1'b0;

    // port 5 (CPU) is driven entirely by the continuous assigns to/from
    // cpu_port_top above -- only ports 0-4 are driven procedurally here
    for (int p = 0; p < NUM_PHYS_PORTS; p++) begin
      alloc_req[p]        = 1'b0;
      enqueue_req[p]       = 1'b0;
      enqueue_bufid[p]     = '0;
      enqueue_length[p]    = '0;
      enqueue_destmask[p]  = '0;
      dequeue_req[p]       = 1'b0;
      release_req[p]       = 1'b0;
      release_bufid[p]     = '0;
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    wait_cycles(5);

    // ---- test A: ingress (CPU TX -> switch), destined for port 2 ----
    begin
      byte data[];
      data = new[37];
      for (int i = 0; i < 37; i++) data[i] = byte'(i + 8'h20);

      dest_mask       = (NUM_PORTS)'(1) << 2;
      dest_mask_valid = 1'b1;
      // dequeue_valid is gated on a level-held dequeue_req (see
      // queue_mgr.sv: req_i = dequeue_req_i & ~queue_empty_vec), so port
      // 2 must be "pulling" throughout for its dequeue_valid to ever
      // assert once the frame lands -- mirrors egress_port_rd.sv's own
      // S_DEQ_WAIT behavior (dequeue_req_o held high while idle).
      dequeue_req[2] = 1'b1;

      send_frame(data);
      // wait for buf_mgr_core's port-2 queue to see the enqueued frame
      begin
        int timeout;
        timeout = 0;
        while (!dequeue_valid[2] && timeout < 1000) begin
          @(posedge clk);
          timeout++;
        end
        if (timeout >= 1000) begin
          $display("FAIL: testA port-2 dequeue_valid never asserted");
          errors++;
        end else if (dequeue_length[2] != LENGTH_W'(37)) begin
          $display("FAIL: testA port-2 length=%0d, expected 37", dequeue_length[2]);
          errors++;
        end else begin
          bit ok;
          int base;
          ok = 1'b1;
          base = int'(dequeue_bufid[2]) * BUFFER_BYTES;
          for (int i = 0; i < 37; i++) if (u_mem.mem[base + i] !== data[i]) ok = 1'b0;
          if (ok) $display("PASS: testA CPU TX frame reproduced exactly in DDR (bufid=%0d, 37 bytes), destined for port 2", dequeue_bufid[2]);
          else begin
            $display("FAIL: testA DDR content mismatch");
            errors++;
          end
        end
      end

      dest_mask_valid = 1'b0;
      dequeue_req[2]  = 1'b0;
    end

    // ---- test B: egress (switch -> CPU RX), originated from port 0 ----
    begin
      byte data[];
      logic [BUF_ID_W-1:0] bufid;
      logic [BUF_ID_W-1:0] bufid2;
      data = new[45];
      for (int i = 0; i < 45; i++) data[i] = byte'(i + 8'h80);

      do_alloc(0, bufid);
      write_ddr_frame(bufid, data);

      cap_reset();
      bp_mode = 1;
      do_enqueue(0, bufid, LENGTH_W'(45), (NUM_PORTS)'(1) << 5);

      wait_cycles(400);

      if (cap_bytes.size() != 45) begin
        $display("FAIL: testB received %0d bytes, expected 45", cap_bytes.size());
        errors++;
      end else begin
        bit ok = 1'b1;
        for (int i = 0; i < 45; i++) if (cap_bytes[i] !== data[i]) ok = 1'b0;
        if (cap_tlast_idx != 44) ok = 1'b0;
        if (ok) $display("PASS: testB CPU RX frame reproduced exactly (45 bytes), tlast placed correctly");
        else begin
          $display("FAIL: testB content/tlast mismatch");
          errors++;
        end
      end
      bp_mode = 0;

      // release round-trip: a fresh alloc should now succeed again
      do_alloc(0, bufid2);
      if (bufid2 !== 'x) $display("PASS: alloc succeeded after release (free list round-trip)");
      else begin
        $display("FAIL: alloc after release timed out");
        errors++;
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
