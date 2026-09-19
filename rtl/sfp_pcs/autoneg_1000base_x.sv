// autoneg_1000base_x.sv
//
// IEEE 802.3 Clause 37 auto-negotiation for 1000BASE-X, sitting alongside
// gmii_1000base_x_tx.sv/gmii_1000base_x_rx.sv/sync_1000base_x.sv inside
// sfp_1000base_x_pcs.sv, at the same single-code-group-per-cycle level
// (clk domain, before that file's 2:1 gearbox to the GTH-parallel
// interface).
//
// The wire-level Config_Reg ordered-set structure (comma + a disparity-
// control symbol + 16-bit data as two data code groups, low byte then
// high byte, four code groups total per ordered set; /C1/ and /C2/
// alternate only on the disparity-control symbol, D21.5 vs D2.2) was NOT
// hand-derived from the IEEE 802.3 primary text -- it was cross-checked
// against a real, working, spec-conformant open-source implementation
// (freecores/1000base-x, rtl/verilog/ge_1000baseX_tx.v, fetched and
// inspected directly, not recalled from training data --
// https://github.com/freecores/1000base-x). That project's
// ge_1000baseX_an.v was used the same way to cross-check the top-level
// state names/structure below (AN_ENABLE/AN_RESTART/ABILITY_DETECT/
// ACKNOWLEDGE_DETECT/COMPLETE_ACKNOWLEDGE/IDLE_DETECT/LINK_OK). The
// SEMANTIC bit-field layout of the 16-bit Config_Reg (which bit is FD,
// HD, pause, remote fault) is NOT independently re-derived from either
// source -- that reference implementation's AN state machine treats the
// register as mostly-opaque data and doesn't comment its bit positions
// either. The layout used here (NP[15], ACK[14], RF[13:12], PS[8:7],
// HD[6], FD[5], reserved elsewhere) follows the commonly-published
// 1000BASE-X Config_Reg layout, at the same secondary-source confidence
// level sync_1000base_x.sv's own header already discloses for its part
// of this PCS. Worth a direct cross-check against IEEE 802.3 Table 37-1
// before hardware bring-up against a real link partner whose duplex/
// pause resolution matters.
//
// Deliberate scope reductions relative to the full Clause 37 state
// diagram (Figure 37-6), each because this project's MAC/PCS don't need
// the omitted behavior, not because it's hard:
//   - Next Page exchange is not implemented (NP is always advertised 0).
//     If a real link partner insists on Next Page, this implementation
//     cannot complete negotiation with it -- acceptable for a simple
//     point-to-point SFP link, not acceptable against every possible
//     real-world partner.
//   - Half-duplex is never advertised (ADV_HALF_DUPLEX defaults to 0):
//     this project's GMII codecs (gmii_1000base_x_tx.sv/_rx.sv) only
//     ever implement full-duplex framing, so advertising HD would let a
//     partner resolve a mode this design can't actually run.
//   - Pause resolution is a simple bitwise AND of both sides' PS[1:0]
//     (mutual "both advertise this Pause variant"), not the full
//     asymmetric-pause resolution table (Annex 28B.3) the real spec
//     uses for finer-grained TX/RX-only Pause combinations.
//   - The RESTART/COMPLETE_ACKNOWLEDGE/IDLE_DETECT timers use small
//     parameterized cycle counts (defaults sized for fast simulation),
//     not the spec's real ~10-20 ms break_link_timer or ~1.6 ms
//     link_timer durations -- override via parameters (using clk's real
//     frequency) before hardware bring-up. Same pattern as
//     LOCK_DELAY_CYCLES in rtl/pl_gmii/pl_eth_clk_gen_sim_model.sv.
//   - IDLE_DETECT reuses this PCS's own Clause 36.2.5.2 data-sync result
//     (sync_1000base_x.sv's sync_ok_o, passed in as pcs_sync_ok_i) as its
//     "the link looks like clean code groups again" signal, rather than
//     building Clause 37.2.5.2's own separate synchronization process --
//     both are fundamentally "is the incoming code-group stream
//     trustworthy", so this project reuses the one sync-quality detector
//     already validated for the data path.
//   - No MAC TX gating: this module does not stall/flow-control
//     open_eth_mac_1g_switch while an_tx_active_o is high. Any MAC frame
//     attempted mid-negotiation is silently discarded at the ordered-set
//     mux in sfp_1000base_x_pcs.sv (an_tx_active_o replaces the whole TX
//     code-group stream, MAC data included) rather than corrupting the
//     negotiation -- acceptable since negotiation happens once at link
//     bring-up before real traffic is expected, but a production design
//     would gate MAC tx_en on link_up_o instead of relying on this.
//
// The received-ordered-set detector is a continuous 4-deep sliding
// window over the raw code-group stream (re-evaluated every cycle, not a
// phase-locked FSM) rather than a hardware comparator array like the
// real MAC's dedicated ability_match/acknowledge_match/consistency_match
// logic: K28.5 can only ever appear on a cycle genuinely flagged
// rxcharisk_i (real frame payload bytes are never K-coded), so a window
// starting at a real comma with D21.5/D2.2 immediately after it cannot
// alias ordinary frame data (Idle's own comma is always followed by
// D16.2 or D5.6, neither of which equals D21.5 or D2.2) -- this is
// simpler than a phase-tracked design and doesn't need re-anchoring
// logic, at the cost of the same "off by one" note below.
//
// The stability requirement ("ability_match"/"acknowledge_match" firing
// only after three consecutive identical received Config_Reg values,
// per spec) is implemented as one shared counter/comparator
// (config_stable_pulse) rather than three separate ones -- the FSM
// below interprets the same pulse differently depending on which state
// it arrives in, matching how ability_match and acknowledge_match are
// really just "the same stabilization event, evaluated in a different
// context" in the spec.

module autoneg_1000base_x
  import sfp_pcs_pkg::*;
#(
  parameter logic       ADV_FULL_DUPLEX    = 1'b1,
  parameter logic       ADV_HALF_DUPLEX    = 1'b0,
  parameter logic [1:0] ADV_PAUSE          = 2'b00,
  parameter int          BREAK_LINK_CYCLES  = 8,
  parameter int          LINK_TIMER_CYCLES  = 8,
  parameter int          IDLE_DETECT_CYCLES = 8
) (
  input  logic clk,
  input  logic rst_n,

  // link-partner code-group stream: the same single-code-group/cycle
  // stream sfp_1000base_x_pcs.sv already feeds to sync_1000base_x.sv/
  // gmii_1000base_x_rx.sv
  input  logic [7:0] rxdata_i,
  input  logic        rxcharisk_i,
  input  logic        rxdisperr_i,
  input  logic        rxnotintable_i,
  input  logic        pcs_sync_ok_i, // sync_1000base_x.sv's sync_ok_o

  // TX ordered-set output + override flag: when an_tx_active_o is high,
  // sfp_1000base_x_pcs.sv must substitute this module's txdata_o/
  // txcharisk_o for gmii_1000base_x_tx.sv's own output that cycle
  output logic        an_tx_active_o,
  output logic [7:0]  txdata_o,
  output logic        txcharisk_o,

  // resolved link status (informational -- not yet wired to any
  // register interface; see header)
  output logic        link_up_o,
  output logic        duplex_full_o,
  output logic [1:0]  pause_o,
  output logic        remote_fault_o
);

  // NP=0(no next page) ACK=0(set later) RF=00(no fault) rsvd=000
  // PS=ADV_PAUSE HD=ADV_HALF_DUPLEX FD=ADV_FULL_DUPLEX rsvd=00000
  localparam logic [15:0] ADV_ABILITY =
    {1'b0, 1'b0, 2'b00, 3'b000, ADV_PAUSE, ADV_HALF_DUPLEX, ADV_FULL_DUPLEX, 5'b00000};

  typedef enum logic [2:0] {
    S_AN_ENABLE, S_AN_RESTART, S_ABILITY_DETECT, S_ACKNOWLEDGE_DETECT,
    S_COMPLETE_ACKNOWLEDGE, S_IDLE_DETECT, S_LINK_OK
  } state_t;
  state_t state_q;

  logic [15:0] tx_config_q;
  logic [15:0] rx_config_latched_q; // latched at ability_match
  logic [31:0] restart_cnt_q, link_timer_cnt_q, idle_cnt_q;

  // ---- RX ordered-set detector: continuous 4-deep sliding window ----
  logic [7:0] g_data_q [4];
  logic       g_isk_q  [4];
  logic       g_ok_q   [4];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin
        g_data_q[i] <= '0;
        g_isk_q[i]  <= 1'b0;
        g_ok_q[i]   <= 1'b0;
      end
    end else begin
      g_data_q[0] <= rxdata_i;
      g_isk_q[0]  <= rxcharisk_i;
      g_ok_q[0]   <= !rxdisperr_i && !rxnotintable_i;
      for (int i = 1; i < 4; i++) begin
        g_data_q[i] <= g_data_q[i-1];
        g_isk_q[i]  <= g_isk_q[i-1];
        g_ok_q[i]   <= g_ok_q[i-1];
      end
    end
  end

  // g_data_q[3] is the oldest sample (expected comma), g_data_q[0] the
  // newest (expected config_hi)
  wire window_ok =
    g_ok_q[3] && g_ok_q[2] && g_ok_q[1] && g_ok_q[0] &&
    g_isk_q[3] && (g_data_q[3] == K28_5) &&
    !g_isk_q[2] && ((g_data_q[2] == D21_5) || (g_data_q[2] == D2_2)) &&
    !g_isk_q[1] && !g_isk_q[0];

  wire [15:0] rx_config_candidate = {g_data_q[0], g_data_q[1]};

  // ---- shared 3-consecutive-identical-values stability detector ----
  logic [15:0] last_candidate_q;
  logic [1:0]  stable_cnt_q;

  wire candidate_matches = window_ok && (rx_config_candidate == last_candidate_q);
  wire candidate_is_new  = window_ok && (rx_config_candidate != last_candidate_q);
  wire [1:0] stable_cnt_next =
    candidate_is_new  ? 2'd1 :
    candidate_matches ? ((stable_cnt_q == 2'd3) ? 2'd3 : stable_cnt_q + 1'b1) :
                         stable_cnt_q;
  wire config_stable_pulse = candidate_matches && (stable_cnt_next == 2'd3);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_candidate_q <= '0;
      stable_cnt_q     <= '0;
    end else begin
      stable_cnt_q <= stable_cnt_next;
      if (candidate_is_new) last_candidate_q <= rx_config_candidate;
    end
  end

  // A stable pulse in IDLE_DETECT/LINK_OK is a harmless pipeline-latency
  // echo of the ordered sets already in flight when an_tx_active dropped
  // -- not a genuine restart -- only when it repeats the exact value we
  // already resolved AND is still ACKed. A partner that has genuinely
  // gone back to AN_ENABLE re-advertises with ACK=0, even when its
  // ability content is unchanged (e.g. its own fixed defaults), so ACK
  // alone is enough to tell a real restart from an echo of agreement.
  wire is_harmless_echo =
    (last_candidate_q[13:0] == rx_config_latched_q[13:0]) && last_candidate_q[14];

  // ---- TX ordered-set generator: comma, disparity symbol (/C1//C2/
  // alternating each completed ordered set), config_lo, config_hi ----
  logic [1:0] tx_pos_q;
  logic       tx_c_toggle_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_pos_q      <= 2'd0;
      tx_c_toggle_q <= 1'b0;
    end else if (!an_tx_active_o) begin
      tx_pos_q <= 2'd0; // always resume on a fresh ordered-set boundary
    end else begin
      tx_pos_q <= tx_pos_q + 1'b1;
      if (tx_pos_q == 2'd3) tx_c_toggle_q <= ~tx_c_toggle_q;
    end
  end

  always_comb begin
    unique case (tx_pos_q)
      2'd0: begin txdata_o = K28_5;                        txcharisk_o = 1'b1; end
      2'd1: begin txdata_o = tx_c_toggle_q ? D2_2 : D21_5;  txcharisk_o = 1'b0; end
      2'd2: begin txdata_o = tx_config_q[7:0];              txcharisk_o = 1'b0; end
      2'd3: begin txdata_o = tx_config_q[15:8];             txcharisk_o = 1'b0; end
      default: begin txdata_o = K28_5; txcharisk_o = 1'b1; end
    endcase
  end

  assign an_tx_active_o = (state_q != S_IDLE_DETECT) && (state_q != S_LINK_OK);

  // ---- main state machine ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q              <= S_AN_ENABLE;
      tx_config_q          <= ADV_ABILITY;
      rx_config_latched_q  <= '0;
      restart_cnt_q        <= '0;
      link_timer_cnt_q     <= '0;
      idle_cnt_q           <= '0;
      link_up_o            <= 1'b0;
      duplex_full_o        <= 1'b0;
      pause_o              <= 2'b00;
      remote_fault_o       <= 1'b0;
    end else begin
      unique case (state_q)
        S_AN_ENABLE: begin
          tx_config_q   <= ADV_ABILITY; // ACK bit clear
          restart_cnt_q <= '0;
          link_up_o     <= 1'b0;
          state_q       <= S_AN_RESTART;
        end

        S_AN_RESTART: begin
          if (restart_cnt_q == BREAK_LINK_CYCLES) begin
            state_q <= S_ABILITY_DETECT;
          end else begin
            restart_cnt_q <= restart_cnt_q + 1'b1;
          end
        end

        S_ABILITY_DETECT: begin
          if (config_stable_pulse) begin
            rx_config_latched_q <= last_candidate_q;
            state_q             <= S_ACKNOWLEDGE_DETECT;
          end
        end

        S_ACKNOWLEDGE_DETECT: begin
          tx_config_q[14] <= 1'b1; // ACK
          if (config_stable_pulse) begin
            if (last_candidate_q[14]) begin // partner's ACK also set
              if (last_candidate_q[13:0] == rx_config_latched_q[13:0]) begin
                link_timer_cnt_q <= '0;
                state_q          <= S_COMPLETE_ACKNOWLEDGE;
              end else begin
                state_q <= S_AN_ENABLE; // inconsistent -- restart
              end
            end
            // partner's ACK not yet set: stay here, keep waiting
          end
        end

        S_COMPLETE_ACKNOWLEDGE: begin
          if (config_stable_pulse && !last_candidate_q[14]) begin
            state_q <= S_AN_ENABLE; // partner dropped ACK -- restart
          end else if (link_timer_cnt_q == LINK_TIMER_CYCLES) begin
            idle_cnt_q <= '0;
            state_q    <= S_IDLE_DETECT;
          end else begin
            link_timer_cnt_q <= link_timer_cnt_q + 1'b1;
          end
        end

        S_IDLE_DETECT: begin
          if (!pcs_sync_ok_i) begin
            state_q <= S_AN_ENABLE;
          end else if (config_stable_pulse && !is_harmless_echo) begin
            // a GENUINE restart -- not just a pipeline-latency echo of
            // the exchange we already resolved (the last one or two
            // ordered sets sent before entering this state are still
            // draining through the TX packer/gth_clk domain crossing/RX
            // unpacker when an_tx_active first drops, so a same-content,
            // still-ACKed stable pulse here is expected and must NOT be
            // treated as the partner restarting). A genuine restart is
            // recognized either by different ability content OR by the
            // ACK bit coming back down (a partner that dropped back to
            // AN_ENABLE re-advertises with ACK=0 even if its ability
            // content happens to be identical, e.g. its own defaults --
            // comparing content alone missed exactly this case) --
            // see is_harmless_echo below.
            state_q <= S_AN_ENABLE;
          end else if (idle_cnt_q == IDLE_DETECT_CYCLES) begin
            link_up_o      <= 1'b1;
            duplex_full_o  <= rx_config_latched_q[5] && ADV_FULL_DUPLEX;
            pause_o        <= rx_config_latched_q[8:7] & ADV_PAUSE;
            remote_fault_o <= |rx_config_latched_q[13:12];
            state_q        <= S_LINK_OK;
          end else begin
            idle_cnt_q <= idle_cnt_q + 1'b1;
          end
        end

        S_LINK_OK: begin
          if (!pcs_sync_ok_i || (config_stable_pulse && !is_harmless_echo)) begin
            state_q   <= S_AN_ENABLE;
            link_up_o <= 1'b0;
          end
        end

        default: state_q <= S_AN_ENABLE;
      endcase
    end
  end

endmodule
