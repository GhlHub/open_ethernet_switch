// mac_addr_resolver.sv
//
// One instance per switch port (5 physical + CPU); the module that was
// missing between the MAC address table (rtl/mac_table/mac_addr_table_top.sv)
// and the ingress datapath's dest_mask_i/dest_mask_valid_i inputs (see
// ingress_port_wr.sv/cpu_port_top.sv's own headers -- both call this out
// as "placeholder until the MAC table is wired in").
//
// Snoops this port's own ingress AXI4-Stream (the same s_axis_* wires
// driving ingress_port_wr -- this module only *reads* them, it never
// drives s_axis_tready) to extract the first 12 bytes of every frame:
// destination MAC (bytes 0-5) then source MAC (bytes 6-11). Once both are
// captured, issues one lookup request (destination MAC -> forwarding
// decision) and one learn request (source MAC -> "this MAC lives behind
// this port") to this port's own dedicated learn/lookup ports on the
// shared mac_addr_table_top instance.
//
// dest_mask_o/dest_mask_valid_o feed ingress_port_wr's dest_mask_i/
// dest_mask_valid_i directly:
//   - lookup hit  -> dest_mask_o = the table's learned one-hot-or-wider
//     port mask for that destination (truncated to NUM_PORTS bits; the
//     table supports up to PORTMASK_W=8 ports, this switch uses 6)
//   - lookup miss -> flood: every port except this one's own. This is
//     also the correct behavior for broadcast/multicast destinations
//     without any separate detection logic, since a multicast bit set in
//     a destination MAC can never match a learned (always-unicast-source)
//     table entry -- it always misses, and always floods.
//   - a malformed/short frame (tlast before 12 bytes captured) resolves
//     straight to dest_mask_o=0 (queue_mgr.sv's enqueue path treats an
//     all-zero destmask as a drop, no refcount taken) instead of issuing
//     any lookup at all -- ingress_port_wr's S_ENQ_WAIT has no timeout,
//     so leaving dest_mask_valid_o low forever on a runt frame would wedge
//     this port permanently.
//
// dest_mask_valid_o is held (not pulsed) from when a result lands until
// the *next* frame's first byte is accepted, which cannot happen before
// ingress_port_wr has consumed the current one (dest_mask_valid_i gates
// its own enqueue, and it won't return to S_RECV -- able to accept a new
// frame's byte 0 -- until after that): the two are naturally sequenced by
// construction, so no busy_i/backpressure handling is needed here beyond
// that.
//
// Internal state (word_pos_q/dest_mac_q/src_mac_q/mask_ready_q/
// dest_mask_q) is updated via combinationally-computed "_next" signals,
// each with exactly one NBA per register in the always_ff -- see
// ingress_port_wr.sv's header for the confirmed Icarus Verilog hazard
// (12.0 and 13.0 alike) this pattern avoids: a register read
// combinationally by build a downstream consumer (here, learn_mac_o/
// lookup_mac_o) on the same cycle it's also updated can otherwise observe
// the wrong (post-edge) value.

module mac_addr_resolver
  import buf_mgr_pkg::*;
  import mac_table_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic clk,
  input  logic rst_n,

  // snooped ingress AXI4-Stream (same wires feeding ingress_port_wr's
  // s_axis_*; not driven here). s_axis_tkeep_i is intentionally unused:
  // any frame that ends (for any reason, at any byte count) before this
  // module has captured all 12 destination+source MAC bytes is treated
  // uniformly as malformed/short via word_pos_q + tlast alone (see the
  // "malformed/short frame" handling below) -- there is no case where the
  // exact tkeep value on a partial final word changes that outcome.
  input  logic [15:0] s_axis_tdata_i,
  input  logic [1:0]  s_axis_tkeep_i,
  input  logic         s_axis_tvalid_i,
  input  logic         s_axis_tlast_i,
  input  logic         s_axis_tready_i,

  // -> ingress_port_wr's dest_mask_i/dest_mask_valid_i
  output logic [NUM_PORTS-1:0] dest_mask_o,
  output logic                 dest_mask_valid_o,

  // -> mac_learn_port #(.PORT_ID(PORT_ID))
  output logic             learn_req_o,
  output logic [MAC_W-1:0] learn_mac_o,

  // -> mac_lookup_port #(.PORT_ID(PORT_ID))
  output logic              lookup_req_o,
  output logic [MAC_W-1:0]  lookup_mac_o,
  input  logic               lookup_result_valid_i,
  input  logic               lookup_result_hit_i,
  input  logic [PORTMASK_W-1:0] lookup_result_port_mask_i
);

  // every port except this one's own -- see header note on flood/miss/
  // broadcast handling
  localparam logic [NUM_PORTS-1:0] FLOOD_MASK = ~(NUM_PORTS'(1) << PORT_ID);

  logic [2:0]  word_pos_q; // 0..5, next word to capture; 6 = parked,
                            // waiting for this frame's own tlast
  logic [47:0] dest_mac_q, src_mac_q;
  logic                 mask_ready_q;
  logic [NUM_PORTS-1:0] dest_mask_q;

  wire word_accept = s_axis_tvalid_i && s_axis_tready_i;

  logic [2:0]  word_pos_next;
  logic [47:0] dest_mac_next, src_mac_next;
  logic                 mask_ready_next;
  logic [NUM_PORTS-1:0] dest_mask_next;
  logic                 issue_req;

  always_comb begin
    word_pos_next   = word_pos_q;
    dest_mac_next   = dest_mac_q;
    src_mac_next    = src_mac_q;
    mask_ready_next = mask_ready_q;
    dest_mask_next  = dest_mask_q;
    issue_req       = 1'b0;

    if (word_accept) begin
      // first byte of a new frame: whatever resolved for the previous one
      // no longer applies to this one
      if (word_pos_q == 3'd0) mask_ready_next = 1'b0;

      if (word_pos_q < 3'd6) begin
        // case on a constant lane index, not a variable/register-indexed
        // part-select write -- see rtl/dma/ingress_port_wr.sv's own
        // accumulator for the same rationale (confirmed Icarus bug with
        // the latter).
        // each 16-bit word holds {byte i+1, byte i} (tdata[7:0]=earlier
        // byte, tdata[15:8]=later byte -- the same convention as every
        // other word-to-byte accumulator in this project); swapped back
        // here so dest_mac_next/src_mac_next hold the MAC in its normal,
        // human-readable byte order (dest_mac[47:40] = the first
        // transmitted byte), matching what a real MAC address means, not
        // just an internally-self-consistent opaque 48-bit key
        unique case (word_pos_q)
          3'd0:    dest_mac_next[47:32] = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]};
          3'd1:    dest_mac_next[31:16] = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]};
          3'd2:    dest_mac_next[15:0]  = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]};
          3'd3:    src_mac_next[47:32]  = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]};
          3'd4:    src_mac_next[31:16]  = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]};
          default: src_mac_next[15:0]   = {s_axis_tdata_i[7:0], s_axis_tdata_i[15:8]}; // word_pos_q==5
        endcase
        if (word_pos_q == 3'd5) issue_req = 1'b1; // source MAC now complete
      end

      if (s_axis_tlast_i) begin
        word_pos_next = '0; // reset for the next frame regardless
        if (word_pos_q < 3'd5) begin
          // malformed/short frame: never captured both MACs (word_pos_q
          // parks at 6 once it does -- see its declaration comment -- so
          // this must check "never reached 5", not "isn't currently 5":
          // that parked state is the *normal* case for any frame longer
          // than 12 bytes, not a malformed one), no lookup was issued --
          // resolve straight to "drop" (see header note)
          mask_ready_next = 1'b1;
          dest_mask_next  = '0;
        end
      end else if (word_pos_q < 3'd6) begin
        word_pos_next = word_pos_q + 1'b1;
      end
    end

    if (lookup_result_valid_i) begin
      mask_ready_next = 1'b1;
      dest_mask_next  = lookup_result_hit_i
        ? lookup_result_port_mask_i[NUM_PORTS-1:0]
        : FLOOD_MASK;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      word_pos_q   <= '0;
      dest_mac_q   <= '0;
      src_mac_q    <= '0;
      mask_ready_q <= 1'b0;
      dest_mask_q  <= '0;
    end else begin
      word_pos_q   <= word_pos_next;
      dest_mac_q   <= dest_mac_next;
      src_mac_q    <= src_mac_next;
      mask_ready_q <= mask_ready_next;
      dest_mask_q  <= dest_mask_next;
    end
  end

  assign dest_mask_valid_o = mask_ready_q;
  assign dest_mask_o       = dest_mask_q;

  // learn_mac_o/lookup_mac_o drive from the *_next combinational signals,
  // not dest_mac_q/src_mac_q: issue_req and the MAC's own final 16 bits
  // are both decided this same cycle (word_pos_q==5's word_accept), so
  // the register itself is still one cycle stale here -- mac_learn_port/
  // mac_lookup_port latch mac_i the same edge req_o is asserted, so this
  // needs to be combinationally current, not the pre-edge register.
  assign learn_req_o  = issue_req;
  assign learn_mac_o  = src_mac_next;
  assign lookup_req_o  = issue_req;
  assign lookup_mac_o  = dest_mac_next;

endmodule
