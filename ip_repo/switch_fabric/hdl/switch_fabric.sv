// Packet storage, forwarding and CPU virtual port. Physical MACs are external.
module switch_fabric
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  import mac_table_pkg::*;
#(parameter bit STATS_DDR=0, STATS_DEBUG=0,
  parameter int AGE_TICK_DIVIDE_COUNT=100_000_000/4) (
  input wire  clk,
  input wire  rst_n,
  input wire  axis_clk,
  input wire  axis_rst_n,
  input wire [AGE_W-1:0]  default_age_i,
  input wire [NUM_PORTS-1:0]  link_up_i,
  input wire [NUM_PORTS-1:0]  link_flush_tog_i,
  output logic link_flush_busy_o,
  input wire [NUM_PORTS-1:0]  learn_en_i,
  input wire [NUM_PORTS-1:0]  fwd_en_i,
  output wire [NUM_PORTS-1:0]  ctrl_frame_o,
  output wire [PORT_ID_W-1:0]  cpu_rx_ingress_port_o,
  output wire  cpu_rx_ingress_valid_o,
  input wire  cpu_rx_ingress_pop_i,
  input wire [15:0]  cpu_s_axis_tdata,
  input wire [1:0]   cpu_s_axis_tkeep,
  input wire  cpu_s_axis_tvalid,
  input wire  cpu_s_axis_tlast,
  output wire  cpu_s_axis_tready,
  output wire [15:0]  cpu_m_axis_tdata,
  output wire [1:0]   cpu_m_axis_tkeep,
  output wire  cpu_m_axis_tvalid,
  output wire  cpu_m_axis_tlast,
  input wire  cpu_m_axis_tready,
  output wire [AXI_ID_W-1:0]    m_axi_ing_awid,
  output wire [AXI_ADDR_W-1:0]  m_axi_ing_awaddr,
  output wire [7:0]             m_axi_ing_awlen,
  output wire [2:0]             m_axi_ing_awsize,
  output wire [1:0]             m_axi_ing_awburst,
  output wire  m_axi_ing_awvalid,
  input wire  m_axi_ing_awready,
  output wire [AXI_DATA_W-1:0]  m_axi_ing_wdata,
  output wire [AXI_STRB_W-1:0]  m_axi_ing_wstrb,
  output wire  m_axi_ing_wlast,
  output wire  m_axi_ing_wvalid,
  input wire  m_axi_ing_wready,
  input wire [AXI_ID_W-1:0]    m_axi_ing_bid,
  input wire [1:0]             m_axi_ing_bresp,
  input wire  m_axi_ing_bvalid,
  output wire  m_axi_ing_bready,
  output wire [AXI_ID_W-1:0]    m_axi_egr_arid,
  output wire [AXI_ADDR_W-1:0]  m_axi_egr_araddr,
  output wire [7:0]             m_axi_egr_arlen,
  output wire [2:0]             m_axi_egr_arsize,
  output wire [1:0]             m_axi_egr_arburst,
  output wire  m_axi_egr_arvalid,
  input wire  m_axi_egr_arready,
  input wire [AXI_ID_W-1:0]    m_axi_egr_rid,
  input wire [AXI_DATA_W-1:0]  m_axi_egr_rdata,
  input wire [1:0]             m_axi_egr_rresp,
  input wire  m_axi_egr_rlast,
  input wire  m_axi_egr_rvalid,
  output wire  m_axi_egr_rready,
  output wire [AXI_ID_W-1:0]    m_axi_cpu_awid,
  output wire [AXI_ADDR_W-1:0]  m_axi_cpu_awaddr,
  output wire [7:0]             m_axi_cpu_awlen,
  output wire [2:0]             m_axi_cpu_awsize,
  output wire [1:0]             m_axi_cpu_awburst,
  output wire  m_axi_cpu_awvalid,
  input wire  m_axi_cpu_awready,
  output wire [AXI_DATA_W-1:0]  m_axi_cpu_wdata,
  output wire [AXI_STRB_W-1:0]  m_axi_cpu_wstrb,
  output wire  m_axi_cpu_wlast,
  output wire  m_axi_cpu_wvalid,
  input wire  m_axi_cpu_wready,
  input wire [AXI_ID_W-1:0]    m_axi_cpu_bid,
  input wire [1:0]             m_axi_cpu_bresp,
  input wire  m_axi_cpu_bvalid,
  output wire  m_axi_cpu_bready,
  output wire [AXI_ID_W-1:0]    m_axi_cpu_arid,
  output wire [AXI_ADDR_W-1:0]  m_axi_cpu_araddr,
  output wire [7:0]             m_axi_cpu_arlen,
  output wire [2:0]             m_axi_cpu_arsize,
  output wire [1:0]             m_axi_cpu_arburst,
  output wire  m_axi_cpu_arvalid,
  input wire  m_axi_cpu_arready,
  input wire [AXI_ID_W-1:0]    m_axi_cpu_rid,
  input wire [AXI_DATA_W-1:0]  m_axi_cpu_rdata,
  input wire [1:0]             m_axi_cpu_rresp,
  input wire  m_axi_cpu_rlast,
  input wire  m_axi_cpu_rvalid,
  output wire  m_axi_cpu_rready,
  input wire [15:0] s00_axis_tdata,
  input wire [15:0] s01_axis_tdata,
  input wire [15:0] s02_axis_tdata,
  input wire [15:0] s03_axis_tdata,
  input wire [15:0] s04_axis_tdata,
  input wire [1:0] s00_axis_tkeep,
  input wire [1:0] s01_axis_tkeep,
  input wire [1:0] s02_axis_tkeep,
  input wire [1:0] s03_axis_tkeep,
  input wire [1:0] s04_axis_tkeep,
  input wire  s00_axis_tvalid,
  input wire  s01_axis_tvalid,
  input wire  s02_axis_tvalid,
  input wire  s03_axis_tvalid,
  input wire  s04_axis_tvalid,
  input wire  s00_axis_tlast,
  input wire  s01_axis_tlast,
  input wire  s02_axis_tlast,
  input wire  s03_axis_tlast,
  input wire  s04_axis_tlast,
  input wire  s00_axis_tuser,
  input wire  s01_axis_tuser,
  input wire  s02_axis_tuser,
  input wire  s03_axis_tuser,
  input wire  s04_axis_tuser,
  output wire  s00_axis_tready,
  output wire  s01_axis_tready,
  output wire  s02_axis_tready,
  output wire  s03_axis_tready,
  output wire  s04_axis_tready,
  output wire [15:0] m00_axis_tdata,
  output wire [15:0] m01_axis_tdata,
  output wire [15:0] m02_axis_tdata,
  output wire [15:0] m03_axis_tdata,
  output wire [15:0] m04_axis_tdata,
  output wire [1:0] m00_axis_tkeep,
  output wire [1:0] m01_axis_tkeep,
  output wire [1:0] m02_axis_tkeep,
  output wire [1:0] m03_axis_tkeep,
  output wire [1:0] m04_axis_tkeep,
  output wire  m00_axis_tvalid,
  output wire  m01_axis_tvalid,
  output wire  m02_axis_tvalid,
  output wire  m03_axis_tvalid,
  output wire  m04_axis_tvalid,
  output wire  m00_axis_tlast,
  output wire  m01_axis_tlast,
  output wire  m02_axis_tlast,
  output wire  m03_axis_tlast,
  output wire  m04_axis_tlast,
  input wire  m00_axis_tready,
  input wire  m01_axis_tready,
  input wire  m02_axis_tready,
  input wire  m03_axis_tready,
  input wire  m04_axis_tready,
  input wire [12:7] stats_req,
  input wire [3:0] stats_select,
  output wire [12:7] stats_acks,
  output wire [12:7][31:0] stats_values
);
  wire [NUM_PHYS_PORTS-1:0][15:0] phy_s_axis_tdata;
  wire [NUM_PHYS_PORTS-1:0][1:0] phy_s_axis_tkeep;
  wire [NUM_PHYS_PORTS-1:0] phy_s_axis_tvalid;
  wire [NUM_PHYS_PORTS-1:0] phy_s_axis_tlast;
  wire [NUM_PHYS_PORTS-1:0] phy_s_axis_tuser;
  wire [NUM_PHYS_PORTS-1:0] phy_s_axis_tready;
  wire [NUM_PHYS_PORTS-1:0][15:0] phy_m_axis_tdata;
  wire [NUM_PHYS_PORTS-1:0][1:0] phy_m_axis_tkeep;
  wire [NUM_PHYS_PORTS-1:0] phy_m_axis_tvalid;
  wire [NUM_PHYS_PORTS-1:0] phy_m_axis_tlast;
  wire [NUM_PHYS_PORTS-1:0] phy_m_axis_tready;
  assign phy_s_axis_tdata[0] = s00_axis_tdata;
  assign phy_s_axis_tdata[1] = s01_axis_tdata;
  assign phy_s_axis_tdata[2] = s02_axis_tdata;
  assign phy_s_axis_tdata[3] = s03_axis_tdata;
  assign phy_s_axis_tdata[4] = s04_axis_tdata;
  assign phy_s_axis_tkeep[0] = s00_axis_tkeep;
  assign phy_s_axis_tkeep[1] = s01_axis_tkeep;
  assign phy_s_axis_tkeep[2] = s02_axis_tkeep;
  assign phy_s_axis_tkeep[3] = s03_axis_tkeep;
  assign phy_s_axis_tkeep[4] = s04_axis_tkeep;
  assign phy_s_axis_tvalid[0] = s00_axis_tvalid;
  assign phy_s_axis_tvalid[1] = s01_axis_tvalid;
  assign phy_s_axis_tvalid[2] = s02_axis_tvalid;
  assign phy_s_axis_tvalid[3] = s03_axis_tvalid;
  assign phy_s_axis_tvalid[4] = s04_axis_tvalid;
  assign phy_s_axis_tlast[0] = s00_axis_tlast;
  assign phy_s_axis_tlast[1] = s01_axis_tlast;
  assign phy_s_axis_tlast[2] = s02_axis_tlast;
  assign phy_s_axis_tlast[3] = s03_axis_tlast;
  assign phy_s_axis_tlast[4] = s04_axis_tlast;
  assign phy_s_axis_tuser[0] = s00_axis_tuser;
  assign phy_s_axis_tuser[1] = s01_axis_tuser;
  assign phy_s_axis_tuser[2] = s02_axis_tuser;
  assign phy_s_axis_tuser[3] = s03_axis_tuser;
  assign phy_s_axis_tuser[4] = s04_axis_tuser;
  assign s00_axis_tready = phy_s_axis_tready[0];
  assign s01_axis_tready = phy_s_axis_tready[1];
  assign s02_axis_tready = phy_s_axis_tready[2];
  assign s03_axis_tready = phy_s_axis_tready[3];
  assign s04_axis_tready = phy_s_axis_tready[4];
  assign m00_axis_tdata = phy_m_axis_tdata[0];
  assign m01_axis_tdata = phy_m_axis_tdata[1];
  assign m02_axis_tdata = phy_m_axis_tdata[2];
  assign m03_axis_tdata = phy_m_axis_tdata[3];
  assign m04_axis_tdata = phy_m_axis_tdata[4];
  assign m00_axis_tkeep = phy_m_axis_tkeep[0];
  assign m01_axis_tkeep = phy_m_axis_tkeep[1];
  assign m02_axis_tkeep = phy_m_axis_tkeep[2];
  assign m03_axis_tkeep = phy_m_axis_tkeep[3];
  assign m04_axis_tkeep = phy_m_axis_tkeep[4];
  assign m00_axis_tvalid = phy_m_axis_tvalid[0];
  assign m01_axis_tvalid = phy_m_axis_tvalid[1];
  assign m02_axis_tvalid = phy_m_axis_tvalid[2];
  assign m03_axis_tvalid = phy_m_axis_tvalid[3];
  assign m04_axis_tvalid = phy_m_axis_tvalid[4];
  assign m00_axis_tlast = phy_m_axis_tlast[0];
  assign m01_axis_tlast = phy_m_axis_tlast[1];
  assign m02_axis_tlast = phy_m_axis_tlast[2];
  assign m03_axis_tlast = phy_m_axis_tlast[3];
  assign m04_axis_tlast = phy_m_axis_tlast[4];
  assign phy_m_axis_tready[0] = m00_axis_tready;
  assign phy_m_axis_tready[1] = m01_axis_tready;
  assign phy_m_axis_tready[2] = m02_axis_tready;
  assign phy_m_axis_tready[3] = m03_axis_tready;
  assign phy_m_axis_tready[4] = m04_axis_tready;



  // =========================================================================
  // age_tick: free-running clock divider off the fabric clock (clk,
  // 100 MHz by default), pulsing age_tick for exactly 1 cycle every
  // AGE_TICK_DIVIDE_COUNT cycles (~1/4 second at the default count) --
  // mac_addr_table_top.sv synchronizes/edge-detects this itself (it need
  // not already be clean in this clock domain, though it already is), so
  // a plain counter-driven pulse is all that's needed here.
  // =========================================================================
  localparam int DIVIDE_CNT_W = $clog2(AGE_TICK_DIVIDE_COUNT);

  logic [DIVIDE_CNT_W-1:0] age_div_cnt_q;
  logic                    age_tick;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      age_div_cnt_q <= '0;
      age_tick      <= 1'b0;
    end else if (age_div_cnt_q == DIVIDE_CNT_W'(AGE_TICK_DIVIDE_COUNT - 1)) begin
      age_div_cnt_q <= '0;
      age_tick      <= 1'b1;
    end else begin
      age_div_cnt_q <= age_div_cnt_q + 1'b1;
      age_tick      <= 1'b0;
    end
  end

  // =========================================================================
  // buf_mgr_core dequeue/release passthrough: ingress_top.sv <-> egress_top.sv
  // =========================================================================
  logic [NUM_PORTS-1:0]               dequeue_req;
  logic [NUM_PORTS-1:0]               dequeue_valid;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length;
  logic [NUM_PORTS-1:0][PORT_ID_W-1:0] dequeue_meta;
  logic [NUM_PORTS-1:0]               release_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid;
  logic [NUM_PORTS-1:0]               release_gnt;

  // =========================================================================
  // CPU port alloc/enqueue (ingress side) <-> ingress_top.sv's cpu_* ports
  // =========================================================================
  logic                cpu_alloc_req, cpu_alloc_gnt;
  logic [BUF_ID_W-1:0] cpu_alloc_bufid;
  logic                     cpu_enqueue_req;
  logic [BUF_ID_W-1:0]      cpu_enqueue_bufid;
  logic [LENGTH_W-1:0]      cpu_enqueue_length;
  logic [NUM_PORTS-1:0]     cpu_enqueue_destmask;
  logic                     cpu_enqueue_gnt;

  // =========================================================================
  // CPU port dequeue/release (egress side) <-> egress_top.sv's cpu_* ports
  // =========================================================================
  logic                cpu_dequeue_valid;
  logic [BUF_ID_W-1:0] cpu_dequeue_bufid;
  logic [LENGTH_W-1:0] cpu_dequeue_length;
  logic                cpu_dequeue_req;
  logic                cpu_release_req;
  logic [BUF_ID_W-1:0] cpu_release_bufid;
  logic                cpu_release_gnt;

  // =========================================================================
  // Per-physical-port ingress AXI4-Stream (MAC -> ingress_top.sv), indexed
  // 0=PS GEM0, 1=PS GEM1, 2=PL GMII0, 3=PL GMII1, 4=SFP0
  // =========================================================================

  // Per-physical-port egress AXI4-Stream (egress_top.sv -> MAC)

  // =========================================================================
  // Forwarding decision, all NUM_PORTS (0-4 physical, 5 CPU)
  // =========================================================================
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] dest_mask;
  logic [NUM_PORTS-1:0]                dest_mask_valid;

  // mac_forwarding_top's snoop inputs mirror the same s_axis_* wires
  // feeding ingress_top.sv (ports 0-4) and cpu_port_top.sv (port 5)
  logic [NUM_PORTS-1:0][15:0] fwd_s_axis_tdata;
  logic [NUM_PORTS-1:0][1:0]  fwd_s_axis_tkeep;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tvalid;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tlast;
  logic [NUM_PORTS-1:0]       fwd_s_axis_tready;

  // The private CPU header and frame share the same DMA stream and clock.
  wire [15:0] cpu_frame_data;
  wire [1:0] cpu_frame_keep;
  wire cpu_frame_valid, cpu_frame_last, cpu_frame_ready, cpu_directed;
  wire [NUM_PORTS-1:0] cpu_frame_dest;
  cpu_tx_framer u_cpu_tx_framer (
    .clk(clk), .rst_n(rst_n),
    .s_data(cpu_s_axis_tdata), .s_keep(cpu_s_axis_tkeep),
    .s_valid(cpu_s_axis_tvalid), .s_last(cpu_s_axis_tlast), .s_ready(cpu_s_axis_tready),
    .m_data(cpu_frame_data), .m_keep(cpu_frame_keep),
    .m_valid(cpu_frame_valid), .m_last(cpu_frame_last), .m_ready(cpu_frame_ready),
    .frame_done(cpu_enqueue_req && cpu_enqueue_gnt),
    .directed(cpu_directed), .dest_mask(cpu_frame_dest)
  );

  assign fwd_s_axis_tdata[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tdata;
  assign fwd_s_axis_tkeep[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tkeep;
  assign fwd_s_axis_tvalid[NUM_PHYS_PORTS-1:0] = phy_s_axis_tvalid;
  assign fwd_s_axis_tlast[NUM_PHYS_PORTS-1:0]  = phy_s_axis_tlast;
  assign fwd_s_axis_tready[NUM_PHYS_PORTS-1:0] = phy_s_axis_tready;

  assign fwd_s_axis_tdata[5]  = cpu_frame_data;
  assign fwd_s_axis_tkeep[5]  = cpu_frame_keep;
  assign fwd_s_axis_tvalid[5] = cpu_frame_valid;
  assign fwd_s_axis_tlast[5]  = cpu_frame_last;
  assign fwd_s_axis_tready[5] = cpu_frame_ready;

  // =========================================================================
  // link state: synchronize into this clock domain, generate flush pulses
  // =========================================================================
  logic [NUM_PORTS-1:0] link_up_sync, link_flush_req;
  logic                 qm_flush_busy, mac_flush_busy;
  port_link_ctrl #(.NUM_PORTS(NUM_PORTS)) u_port_link_ctrl (
    .clk (clk), .rst_n (rst_n),
    .link_up_async_i (link_up_i), .flush_tog_async_i (link_flush_tog_i),
    .link_up_o (link_up_sync), .flush_req_o (link_flush_req)
  );
  // registered before leaving the domain (the consumer synchronizes it into the
  // AXI-Lite clock; a gate in front of the synchronizer would be a CDC hazard)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) link_flush_busy_o <= 1'b0;
    else        link_flush_busy_o <= qm_flush_busy | mac_flush_busy;
  end

  // ---- learn_en_i/fwd_en_i: plain 2-flop level synchronizers (not the
  // flush-toggle machinery port_link_ctrl provides -- these are held levels
  // with no associated drain event of their own; entering a state that
  // disables forwarding is expected to arrive together with a LINK_CLR-style
  // flush from software if one is wanted, same as this project's other
  // "purge on the way down" transitions) ----
  (* ASYNC_REG = "TRUE" *) logic [NUM_PORTS-1:0] learn_en_s1, learn_en_s2;
  (* ASYNC_REG = "TRUE" *) logic [NUM_PORTS-1:0] fwd_en_s1, fwd_en_s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      learn_en_s1 <= '1; learn_en_s2 <= '1;
      fwd_en_s1   <= '1; fwd_en_s2   <= '1;
    end else begin
      learn_en_s1 <= learn_en_i; learn_en_s2 <= learn_en_s1;
      fwd_en_s1   <= fwd_en_i;   fwd_en_s2   <= fwd_en_s1;
    end
  end

  // ---- CPU RX ingress-port tag: clk -> axis_clk, one entry per frame this
  // module hands to the CPU DMA (see cpu_rx_ingress_* ports above). Pushed
  // on dequeue_valid[5] -- queue_mgr.sv's per-port queue for the CPU is a
  // single serialized engine, so dequeues (and therefore this push) happen
  // in exactly the order cpu_dma_rd.sv/egress_port_rd#(.PORT_ID(5)) then
  // stream those frames out to the CPU-facing AXI DMA, and a link-down
  // flush of the CPU port releases buffers without ever asserting
  // dequeue_valid -- so a frame that never reaches the CPU never pushes an
  // entry here either. Depth 16 matches fabric_dma.c's own RX descriptor
  // ring size (software cannot have more than that many frames
  // outstanding). Software must pop exactly one entry per DMA descriptor
  // it retires (whether or not that frame turned out well-formed) to stay
  // in lockstep -- see fabric_dma.c's header for how it does this.
  logic cpu_rx_tag_empty;
  async_fifo #(.WIDTH(PORT_ID_W), .DEPTH(16)) u_cpu_rx_tag_fifo (
    .wr_clk   (clk),
    .wr_rst_n (rst_n),
    .wr_en_i  (dequeue_valid[5]),
    .wr_data_i(dequeue_meta[5]),
    .full_o   (),
    .rd_clk   (axis_clk),
    .rd_rst_n (axis_rst_n),
    .rd_en_i  (cpu_rx_ingress_pop_i),
    .rd_data_o(cpu_rx_ingress_port_o),
    .empty_o  (cpu_rx_tag_empty)
  );
  assign cpu_rx_ingress_valid_o = !cpu_rx_tag_empty;

  // =========================================================================
  // Shared buffer manager and independent ingress datapath
  // =========================================================================
  // ---- buf_mgr_core ----
  logic [NUM_PORTS-1:0]               alloc_req, alloc_gnt;
  logic [BUF_ID_W-1:0]                alloc_bufid;
  logic [NUM_PORTS-1:0]                enqueue_req;
  logic [NUM_PORTS-1:0][BUF_ID_W-1:0]  enqueue_bufid;
  logic [NUM_PORTS-1:0][LENGTH_W-1:0]  enqueue_length;
  logic [NUM_PORTS-1:0][NUM_PORTS-1:0] enqueue_destmask;
  // Ingress-port tag: for the 5 physical ports this is simply their own
  // fixed PORT_ID (known at elaboration time, tied below); the CPU port's
  // own slot is never read back (nothing dequeues port 5's queue at port
  // 5), so it's tied to a fixed placeholder value too.
  logic [NUM_PORTS-1:0][PORT_ID_W-1:0] enqueue_meta;
  logic [NUM_PORTS-1:0]                enqueue_gnt;

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
    .enqueue_meta_i     (enqueue_meta),
    .enqueue_gnt_o      (enqueue_gnt),
    .dequeue_req_i      (dequeue_req),
    .dequeue_valid_o    (dequeue_valid),
    .dequeue_bufid_o    (dequeue_bufid),
    .dequeue_length_o   (dequeue_length),
    .dequeue_meta_o     (dequeue_meta),
    .release_req_i      (release_req),
    .release_bufid_i    (release_bufid),
    .release_gnt_o      (release_gnt),
    .link_up_i          (link_up_sync),
    .flush_req_i        (link_flush_req),
    .flush_busy_o       (qm_flush_busy)
  );

  // CPU (port 5) alloc/enqueue: driven by the external cpu_* signals,
  // fed into buf_mgr_core's port-5 slot. alloc_gnt/alloc_bufid/
  // enqueue_gnt are buf_mgr_core outputs (driven by the instance above)
  // -- read from them here, don't drive them.
  assign alloc_req[5]        = cpu_alloc_req;
  assign cpu_alloc_gnt     = alloc_gnt[5];
  assign cpu_alloc_bufid   = alloc_bufid;

  assign enqueue_req[5]      = cpu_enqueue_req;
  assign enqueue_bufid[5]    = cpu_enqueue_bufid;
  assign enqueue_length[5]   = cpu_enqueue_length;
  assign enqueue_destmask[5] = cpu_enqueue_destmask;
  assign enqueue_meta[5]     = PORT_ID_W'(5); // never read back; see note above
  assign cpu_enqueue_gnt   = enqueue_gnt[5];

  for (genvar p=0; p<NUM_PHYS_PORTS; p++) begin : tags
    assign enqueue_meta[p] = PORT_ID_W'(p);
  end
  ingress_datapath u_ingress (
    .clk(clk),
    .rst_n(rst_n),
    .s_axis_tdata(phy_s_axis_tdata),
    .s_axis_tkeep(phy_s_axis_tkeep),
    .s_axis_tvalid(phy_s_axis_tvalid),
    .s_axis_tlast(phy_s_axis_tlast),
    .s_axis_tuser(phy_s_axis_tuser),
    .s_axis_tready(phy_s_axis_tready),
    .dest_mask_i(dest_mask[NUM_PHYS_PORTS-1:0]),
    .dest_mask_valid_i(dest_mask_valid[NUM_PHYS_PORTS-1:0]),
    .m_axi_awid(m_axi_ing_awid),
    .m_axi_awaddr(m_axi_ing_awaddr),
    .m_axi_awlen(m_axi_ing_awlen),
    .m_axi_awsize(m_axi_ing_awsize),
    .m_axi_awburst(m_axi_ing_awburst),
    .m_axi_awvalid(m_axi_ing_awvalid),
    .m_axi_awready(m_axi_ing_awready),
    .m_axi_wdata(m_axi_ing_wdata),
    .m_axi_wstrb(m_axi_ing_wstrb),
    .m_axi_wlast(m_axi_ing_wlast),
    .m_axi_wvalid(m_axi_ing_wvalid),
    .m_axi_wready(m_axi_ing_wready),
    .m_axi_bid(m_axi_ing_bid),
    .m_axi_bresp(m_axi_ing_bresp),
    .m_axi_bvalid(m_axi_ing_bvalid),
    .m_axi_bready(m_axi_ing_bready),
    .alloc_req(alloc_req[NUM_PHYS_PORTS-1:0]),
    .alloc_gnt(alloc_gnt[NUM_PHYS_PORTS-1:0]),
    .alloc_bufid(alloc_bufid),
    .enqueue_req(enqueue_req[NUM_PHYS_PORTS-1:0]),
    .enqueue_bufid(enqueue_bufid[NUM_PHYS_PORTS-1:0]),
    .enqueue_length(enqueue_length[NUM_PHYS_PORTS-1:0]),
    .enqueue_destmask(enqueue_destmask[NUM_PHYS_PORTS-1:0]),
    .enqueue_gnt(enqueue_gnt[NUM_PHYS_PORTS-1:0])
  );

  // =========================================================================
  // egress_top.sv
  // =========================================================================
  egress_top u_egress_top (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .m_axis_tdata              (phy_m_axis_tdata),
    .m_axis_tkeep              (phy_m_axis_tkeep),
    .m_axis_tvalid             (phy_m_axis_tvalid),
    .m_axis_tlast              (phy_m_axis_tlast),
    .m_axis_tready             (phy_m_axis_tready),
    .m_axi_arid                (m_axi_egr_arid),
    .m_axi_araddr              (m_axi_egr_araddr),
    .m_axi_arlen               (m_axi_egr_arlen),
    .m_axi_arsize              (m_axi_egr_arsize),
    .m_axi_arburst             (m_axi_egr_arburst),
    .m_axi_arvalid             (m_axi_egr_arvalid),
    .m_axi_arready             (m_axi_egr_arready),
    .m_axi_rid                 (m_axi_egr_rid),
    .m_axi_rdata                (m_axi_egr_rdata),
    .m_axi_rresp                (m_axi_egr_rresp),
    .m_axi_rlast                (m_axi_egr_rlast),
    .m_axi_rvalid                (m_axi_egr_rvalid),
    .m_axi_rready                (m_axi_egr_rready),
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

  // =========================================================================
  // cpu_port_top.sv
  // =========================================================================
  cpu_port_top u_cpu_port_top (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .s_axis_tdata           (cpu_frame_data),
    .s_axis_tkeep           (cpu_frame_keep),
    .s_axis_tvalid          (cpu_frame_valid),
    .s_axis_tlast           (cpu_frame_last),
    .s_axis_tready          (cpu_frame_ready),
    .m_axis_tdata           (cpu_m_axis_tdata),
    .m_axis_tkeep           (cpu_m_axis_tkeep),
    .m_axis_tvalid          (cpu_m_axis_tvalid),
    .m_axis_tlast           (cpu_m_axis_tlast),
    .m_axis_tready          (cpu_m_axis_tready),
    // Directed metadata belongs to this frame and stays stable through enqueue.
    .dest_mask_i            (cpu_directed ? cpu_frame_dest : dest_mask[5]),
    .dest_mask_valid_i      (cpu_directed ? 1'b1 : dest_mask_valid[5]),
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
    .m_axi_awid             (m_axi_cpu_awid),
    .m_axi_awaddr           (m_axi_cpu_awaddr),
    .m_axi_awlen            (m_axi_cpu_awlen),
    .m_axi_awsize           (m_axi_cpu_awsize),
    .m_axi_awburst          (m_axi_cpu_awburst),
    .m_axi_awvalid          (m_axi_cpu_awvalid),
    .m_axi_awready          (m_axi_cpu_awready),
    .m_axi_wdata            (m_axi_cpu_wdata),
    .m_axi_wstrb            (m_axi_cpu_wstrb),
    .m_axi_wlast            (m_axi_cpu_wlast),
    .m_axi_wvalid           (m_axi_cpu_wvalid),
    .m_axi_wready           (m_axi_cpu_wready),
    .m_axi_bid              (m_axi_cpu_bid),
    .m_axi_bresp            (m_axi_cpu_bresp),
    .m_axi_bvalid           (m_axi_cpu_bvalid),
    .m_axi_bready           (m_axi_cpu_bready),
    .m_axi_arid             (m_axi_cpu_arid),
    .m_axi_araddr           (m_axi_cpu_araddr),
    .m_axi_arlen            (m_axi_cpu_arlen),
    .m_axi_arsize           (m_axi_cpu_arsize),
    .m_axi_arburst          (m_axi_cpu_arburst),
    .m_axi_arvalid          (m_axi_cpu_arvalid),
    .m_axi_arready          (m_axi_cpu_arready),
    .m_axi_rid              (m_axi_cpu_rid),
    .m_axi_rdata            (m_axi_cpu_rdata),
    .m_axi_rresp            (m_axi_cpu_rresp),
    .m_axi_rlast            (m_axi_cpu_rlast),
    .m_axi_rvalid           (m_axi_cpu_rvalid),
    .m_axi_rready           (m_axi_cpu_rready)
  );

  // =========================================================================
  // mac_forwarding_top.sv
  // =========================================================================
  mac_forwarding_top u_mac_forwarding_top (
    .clk               (clk),
    .rst_n             (rst_n),
    .age_tick_i        (age_tick),
    .default_age_i     (default_age_i),
    .flush_req_i       (link_flush_req),
    .flush_busy_o      (mac_flush_busy),
    .s_axis_tdata_i    (fwd_s_axis_tdata),
    .s_axis_tkeep_i    (fwd_s_axis_tkeep),
    .s_axis_tvalid_i   (fwd_s_axis_tvalid),
    .s_axis_tlast_i    (fwd_s_axis_tlast),
    .s_axis_tready_i   (fwd_s_axis_tready),
    .dest_mask_o       (dest_mask),
    .dest_mask_valid_o (dest_mask_valid),
    .learn_en_i        (learn_en_s2),
    .fwd_en_i          (fwd_en_s2),
    .ctrl_frame_o      (ctrl_frame_o)
  );

  // =========================================================================
  // PS GEM0 (port 0) / PS GEM1 (port 1)
  // =========================================================================
  // =========================================================================
  // PL GMII0 (port 2) / PL GMII1 (port 3)
  // =========================================================================
  // =========================================================================
  // SFP0 (port 4)
  // =========================================================================

  wire [7:0][31:0] stats_cpu_inc;
  stats_axis stats_cpu_s (.clk(clk),.rst_n(rst_n),.valid(cpu_frame_valid),.ready(cpu_frame_ready),
    .last(cpu_frame_last),.bad(1'b0),.keep(cpu_frame_keep),.increment(stats_cpu_inc[0 +: 4]));
  stats_axis stats_cpu_m (.clk(clk),.rst_n(rst_n),.valid(cpu_m_axis_tvalid),.ready(cpu_m_axis_tready),
    .last(cpu_m_axis_tlast),.bad(1'b0),.keep(cpu_m_axis_tkeep),.increment(stats_cpu_inc[4 +: 4]));
  stats_bank stats_cpu_bank (.clk(clk),.rst_n(rst_n),.increment(stats_cpu_inc),
    .request(stats_req[7]),.select(stats_select),.ack(stats_acks[7]),.value(stats_values[7]));
  generate if (STATS_DDR) begin : ddr_statistics
    stats_axi #(.BYTES(AXI_STRB_W),.WRITE(1'b1)) monitor8 (.clk(clk),.rst_n(rst_n),
      .address_valid(m_axi_ing_awvalid),.address_ready(m_axi_ing_awready),
      .data_valid(m_axi_ing_wvalid),.data_ready(m_axi_ing_wready),
      .strobe(m_axi_ing_wstrb),
      .response_valid(m_axi_ing_bvalid),.response_ready(m_axi_ing_bready),
      .response_last(1'b1),.response(m_axi_ing_bresp),
      .request(stats_req[8]),.select(stats_select),.ack(stats_acks[8]),.value(stats_values[8]));
    stats_axi #(.BYTES(AXI_STRB_W),.WRITE(1'b0)) monitor9 (.clk(clk),.rst_n(rst_n),
      .address_valid(m_axi_egr_arvalid),.address_ready(m_axi_egr_arready),
      .data_valid(m_axi_egr_rvalid),.data_ready(m_axi_egr_rready),
      .strobe({AXI_STRB_W{1'b1}}),
      .response_valid(m_axi_egr_rvalid),.response_ready(m_axi_egr_rready),
      .response_last(m_axi_egr_rlast),.response(m_axi_egr_rresp),
      .request(stats_req[9]),.select(stats_select),.ack(stats_acks[9]),.value(stats_values[9]));
    stats_axi #(.BYTES(AXI_STRB_W),.WRITE(1'b1)) monitor10 (.clk(clk),.rst_n(rst_n),
      .address_valid(m_axi_cpu_awvalid),.address_ready(m_axi_cpu_awready),
      .data_valid(m_axi_cpu_wvalid),.data_ready(m_axi_cpu_wready),
      .strobe(m_axi_cpu_wstrb),
      .response_valid(m_axi_cpu_bvalid),.response_ready(m_axi_cpu_bready),
      .response_last(1'b1),.response(m_axi_cpu_bresp),
      .request(stats_req[10]),.select(stats_select),.ack(stats_acks[10]),.value(stats_values[10]));
    stats_axi #(.BYTES(AXI_STRB_W),.WRITE(1'b0)) monitor11 (.clk(clk),.rst_n(rst_n),
      .address_valid(m_axi_cpu_arvalid),.address_ready(m_axi_cpu_arready),
      .data_valid(m_axi_cpu_rvalid),.data_ready(m_axi_cpu_rready),
      .strobe({AXI_STRB_W{1'b1}}),
      .response_valid(m_axi_cpu_rvalid),.response_ready(m_axi_cpu_rready),
      .response_last(m_axi_cpu_rlast),.response(m_axi_cpu_rresp),
      .request(stats_req[11]),.select(stats_select),.ack(stats_acks[11]),.value(stats_values[11]));
  end else begin : no_ddr_statistics
    assign stats_acks[11:8] = stats_req[11:8];
    assign stats_values[11:8] = '0;
  end endgenerate
  generate if (STATS_DEBUG) begin : debug_statistics
    wire [15:0][31:0] inc;
    for (genvar k=0;k<5;k=k+1) begin : stalls
      assign inc[k] = 32'(phy_s_axis_tvalid[k] && !phy_s_axis_tready[k]);
      assign inc[k+5] = 32'(phy_m_axis_tvalid[k] && !phy_m_axis_tready[k]);
    end
    assign inc[10] = 32'(cpu_s_axis_tvalid && !cpu_s_axis_tready);
    assign inc[11] = 32'(cpu_m_axis_tvalid && !cpu_m_axis_tready);
    assign inc[12] = 32'(cpu_alloc_req && !cpu_alloc_gnt);
    assign inc[13] = 32'(cpu_enqueue_req && !cpu_enqueue_gnt);
    assign inc[14] = 32'(link_flush_busy_o);
    assign inc[15] = 32'(m_axi_ing_bvalid && m_axi_ing_bready && m_axi_ing_bresp[1]) +
                     32'(m_axi_egr_rvalid && m_axi_egr_rready && m_axi_egr_rresp[1]) +
                     32'(m_axi_cpu_bvalid && m_axi_cpu_bready && m_axi_cpu_bresp[1]) +
                     32'(m_axi_cpu_rvalid && m_axi_cpu_rready && m_axi_cpu_rresp[1]);
    stats_bank #(.N(16),.WIDTH(28)) bank (.clk(clk),.rst_n(rst_n),.increment(inc),
      .request(stats_req[12]),.select(stats_select),.ack(stats_acks[12]),.value(stats_values[12]));
  end else begin : no_debug_statistics
    assign stats_acks[12] = stats_req[12];
    assign stats_values[12] = 0;
  end endgenerate

endmodule
