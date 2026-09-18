// egress_top.sv
//
// Wires the 5 physical egress front-ends and the shared AXI4 read engine
// together. Mirrors ingress_top.sv but does NOT instantiate buf_mgr_core
// itself -- that instance already lives in ingress_top.sv, so this
// module's dequeue/release ports for all NUM_PORTS (5 physical + CPU)
// are meant to be wired directly to ingress_top.sv's own dequeue/release
// passthrough ports at a higher-level top that instantiates both. This
// module drives/consumes only the 5 physical ports' slots internally;
// the CPU port's (index 5) slot is exposed separately for a future CPU
// TX interface to drive.

module egress_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream TX to the 5 MACs (16-bit, 62.5 MHz)
  output logic [NUM_PHYS_PORTS-1:0][15:0] m_axis_tdata,
  output logic [NUM_PHYS_PORTS-1:0][1:0]  m_axis_tkeep,
  output logic [NUM_PHYS_PORTS-1:0]       m_axis_tvalid,
  output logic [NUM_PHYS_PORTS-1:0]       m_axis_tlast,
  input  logic [NUM_PHYS_PORTS-1:0]       m_axis_tready,

  // AXI4 read master
  output logic [AXI_ID_W-1:0]   m_axi_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,
  input  logic [AXI_ID_W-1:0]   m_axi_rid,
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready,

  // buf_mgr_core dequeue (all 6 ports) + release (all 6 ports) --
  // pass-through to/from ingress_top.sv's own passthrough ports
  output logic [NUM_PORTS-1:0]               dequeue_req_o_passthru,
  input  logic [NUM_PORTS-1:0]               dequeue_valid_i_passthru,
  input  logic [NUM_PORTS-1:0][BUF_ID_W-1:0] dequeue_bufid_i_passthru,
  input  logic [NUM_PORTS-1:0][LENGTH_W-1:0] dequeue_length_i_passthru,
  output logic [NUM_PORTS-1:0]               release_req_o_passthru,
  output logic [NUM_PORTS-1:0][BUF_ID_W-1:0] release_bufid_o_passthru,
  input  logic [NUM_PORTS-1:0]               release_gnt_i_passthru,

  // CPU port (index 5) dequeue/release -- for a future CPU TX interface
  // to drive/consume, passed through to the passthru arrays' index 5 here
  output logic                cpu_dequeue_valid_o,
  output logic [BUF_ID_W-1:0] cpu_dequeue_bufid_o,
  output logic [LENGTH_W-1:0] cpu_dequeue_length_o,
  input  logic                cpu_dequeue_req_i,
  input  logic                cpu_release_req_i,
  input  logic [BUF_ID_W-1:0] cpu_release_bufid_i,
  output logic                cpu_release_gnt_o
);

  genvar gi;

  // CPU (port 5) dequeue/release: pass straight through to/from the
  // external cpu_* signals.
  assign dequeue_req_o_passthru[5]  = cpu_dequeue_req_i;
  assign cpu_dequeue_valid_o        = dequeue_valid_i_passthru[5];
  assign cpu_dequeue_bufid_o        = dequeue_bufid_i_passthru[5];
  assign cpu_dequeue_length_o       = dequeue_length_i_passthru[5];

  assign release_req_o_passthru[5]   = cpu_release_req_i;
  assign release_bufid_o_passthru[5] = cpu_release_bufid_i;
  assign cpu_release_gnt_o           = release_gnt_i_passthru[5];

  // ---- 5 physical egress front-ends + shared read engine ----
  logic [NUM_PHYS_PORTS-1:0]                 frame_req;
  logic [NUM_PHYS_PORTS-1:0][BUF_ID_W-1:0]   frame_bufid;
  logic [NUM_PHYS_PORTS-1:0][LENGTH_W-1:0]   frame_length;
  logic [NUM_PHYS_PORTS-1:0]                 frame_gnt;
  logic [NUM_PHYS_PORTS-1:0]                 frame_wr_en;
  logic [BEAT_IDX_W-1:0]                     frame_wr_addr;
  logic [AXI_DATA_W-1:0]                     frame_wr_data;
  logic [NUM_PHYS_PORTS-1:0]                 frame_dma_done;

  generate
    for (gi = 0; gi < NUM_PHYS_PORTS; gi++) begin : g_egress_ports
      egress_port_rd #(.PORT_ID(gi)) u_port (
        .clk               (clk),
        .rst_n             (rst_n),
        .m_axis_tdata      (m_axis_tdata[gi]),
        .m_axis_tkeep      (m_axis_tkeep[gi]),
        .m_axis_tvalid     (m_axis_tvalid[gi]),
        .m_axis_tlast      (m_axis_tlast[gi]),
        .m_axis_tready     (m_axis_tready[gi]),
        .dequeue_req_o     (dequeue_req_o_passthru[gi]),
        .dequeue_valid_i   (dequeue_valid_i_passthru[gi]),
        .dequeue_bufid_i   (dequeue_bufid_i_passthru[gi]),
        .dequeue_length_i  (dequeue_length_i_passthru[gi]),
        .release_req_o     (release_req_o_passthru[gi]),
        .release_bufid_o   (release_bufid_o_passthru[gi]),
        .release_gnt_i     (release_gnt_i_passthru[gi]),
        .frame_req_o       (frame_req[gi]),
        .frame_bufid_o     (frame_bufid[gi]),
        .frame_length_o    (frame_length[gi]),
        .frame_gnt_i       (frame_gnt[gi]),
        .frame_wr_en_i     (frame_wr_en[gi]),
        .frame_wr_addr_i   (frame_wr_addr),
        .frame_wr_data_i   (frame_wr_data),
        .frame_dma_done_i  (frame_dma_done[gi])
      );
    end
  endgenerate

  egress_dma_rd u_dma_rd (
    .clk              (clk),
    .rst_n            (rst_n),
    .frame_req_i      (frame_req),
    .frame_bufid_i    (frame_bufid),
    .frame_length_i   (frame_length),
    .frame_gnt_o      (frame_gnt),
    .frame_wr_en_o    (frame_wr_en),
    .frame_wr_addr_o  (frame_wr_addr),
    .frame_wr_data_o  (frame_wr_data),
    .frame_dma_done_o (frame_dma_done),
    .m_axi_arid       (m_axi_arid),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arlen      (m_axi_arlen),
    .m_axi_arsize     (m_axi_arsize),
    .m_axi_arburst    (m_axi_arburst),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_rid        (m_axi_rid),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rlast      (m_axi_rlast),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready)
  );

endmodule
