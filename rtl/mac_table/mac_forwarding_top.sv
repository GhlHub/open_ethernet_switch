// mac_forwarding_top.sv
//
// Joins the shared mac_addr_table_top instance with one mac_addr_resolver
// per switch port (buf_mgr_pkg::NUM_PORTS = 5 physical + CPU), closing the
// loop this project had documented but never built: each resolver snoops
// its own port's ingress AXI4-Stream and drives that same port's
// dest_mask_i/dest_mask_valid_i (see mac_addr_resolver.sv's header).
//
// mac_addr_table_top supports up to mac_table_pkg::NUM_LEARN_PORTS/
// NUM_LOOKUP_PORTS (8 each); this switch only uses NUM_PORTS (6) of them,
// so the upper (NUM_LEARN_PORTS-NUM_PORTS)/(NUM_LOOKUP_PORTS-NUM_PORTS)
// slots are tied off, unused.
//
// age_tick_i/default_age_i are passed straight through to
// mac_addr_table_top -- generating an actual ~4Hz tick is a system-
// integration concern (a clock-divided counter) not scoped here.
//
// Not yet connected to anything: this module's s_axis_*_i snoop inputs
// need to be wired to the same physical-port/CPU-port s_axis_* signals
// that also feed ingress_top.sv/cpu_port_top.sv, and its dest_mask_o/
// dest_mask_valid_o outputs to their dest_mask_i/dest_mask_valid_i
// inputs -- both currently exposed as raw top-level ports on those
// modules (see their own headers), meant for exactly this. That joining
// happens at whatever future top level (switch_top.sv, not yet built)
// instantiates ingress_top.sv, cpu_port_top.sv, and this module together.

module mac_forwarding_top
  import buf_mgr_pkg::*;
  import mac_table_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic              age_tick_i,
  input  logic [AGE_W-1:0]  default_age_i,

  // link-down: a one-cycle pulse on bit p expires every learned entry of port p
  input  logic [NUM_PORTS-1:0] flush_req_i,
  output logic                 flush_busy_o,

  // snooped ingress AXI4-Stream, one set per switch port (same wires
  // feeding ingress_port_wr.sv's s_axis_* for ports 0-4, and
  // cpu_port_top.sv's s_axis_* for port 5); not driven here
  input  logic [NUM_PORTS-1:0][15:0] s_axis_tdata_i,
  input  logic [NUM_PORTS-1:0][1:0]  s_axis_tkeep_i,
  input  logic [NUM_PORTS-1:0]       s_axis_tvalid_i,
  input  logic [NUM_PORTS-1:0]       s_axis_tlast_i,
  input  logic [NUM_PORTS-1:0]       s_axis_tready_i,

  // -> ingress_port_wr.sv's dest_mask_i/dest_mask_valid_i (ports 0-4) and
  // cpu_port_top.sv's (port 5)
  output logic [NUM_PORTS-1:0][NUM_PORTS-1:0] dest_mask_o,
  output logic [NUM_PORTS-1:0]                dest_mask_valid_o,

  // per-port control state, already synchronized into this clock domain by
  // the caller (see mac_addr_resolver.sv's header); both default-tied
  // enabled by switch_top.sv until software drives them
  input  logic [NUM_PORTS-1:0] learn_en_i,
  input  logic [NUM_PORTS-1:0] fwd_en_i,
  output logic [NUM_PORTS-1:0] ctrl_frame_o
);

  genvar gi;

  logic [NUM_LEARN_PORTS-1:0]            learn_req;
  logic [NUM_LEARN_PORTS-1:0][MAC_W-1:0] learn_mac;

  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_req;
  logic [NUM_LOOKUP_PORTS-1:0][MAC_W-1:0]      lookup_mac;
  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_result_valid;
  logic [NUM_LOOKUP_PORTS-1:0]                 lookup_result_hit;
  logic [NUM_LOOKUP_PORTS-1:0][PORTMASK_W-1:0] lookup_result_port_mask;

  // unused learn/lookup port slots (NUM_PORTS..NUM_LEARN_PORTS-1 /
  // NUM_PORTS..NUM_LOOKUP_PORTS-1): tied off
  assign learn_req[NUM_LEARN_PORTS-1:NUM_PORTS]   = '0;
  assign learn_mac[NUM_LEARN_PORTS-1:NUM_PORTS]   = '0;
  assign lookup_req[NUM_LOOKUP_PORTS-1:NUM_PORTS] = '0;
  assign lookup_mac[NUM_LOOKUP_PORTS-1:NUM_PORTS] = '0;

  mac_addr_table_top u_table (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .age_tick_i                (age_tick_i),
    .default_age_i             (default_age_i),
    .flush_req_i               (PORTMASK_W'(flush_req_i)),
    .flush_busy_o              (flush_busy_o),
    .learn_req_i               (learn_req),
    .learn_mac_i               (learn_mac),
    .learn_busy_o              (),
    .lookup_req_i              (lookup_req),
    .lookup_mac_i              (lookup_mac),
    .lookup_busy_o             (),
    .lookup_result_valid_o     (lookup_result_valid),
    .lookup_result_hit_o       (lookup_result_hit),
    .lookup_result_port_mask_o (lookup_result_port_mask)
  );

  generate
    for (gi = 0; gi < NUM_PORTS; gi++) begin : g_resolver
      mac_addr_resolver #(.PORT_ID(gi)) u_resolver (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .s_axis_tdata_i            (s_axis_tdata_i[gi]),
        .s_axis_tkeep_i            (s_axis_tkeep_i[gi]),
        .s_axis_tvalid_i           (s_axis_tvalid_i[gi]),
        .s_axis_tlast_i            (s_axis_tlast_i[gi]),
        .s_axis_tready_i           (s_axis_tready_i[gi]),
        .learn_en_i                (learn_en_i[gi]),
        .fwd_en_i                  (fwd_en_i[gi]),
        .dest_mask_o               (dest_mask_o[gi]),
        .dest_mask_valid_o         (dest_mask_valid_o[gi]),
        .ctrl_frame_o              (ctrl_frame_o[gi]),
        .learn_req_o               (learn_req[gi]),
        .learn_mac_o               (learn_mac[gi]),
        .lookup_req_o              (lookup_req[gi]),
        .lookup_mac_o              (lookup_mac[gi]),
        .lookup_result_valid_i     (lookup_result_valid[gi]),
        .lookup_result_hit_i       (lookup_result_hit[gi]),
        .lookup_result_port_mask_i (lookup_result_port_mask[gi])
      );
    end
  endgenerate

endmodule
