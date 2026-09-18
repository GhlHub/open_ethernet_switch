# Design inventory verification

Date: 2026-09-18. This update adds checks for the RGMII and PL clock-generator
behavioral models. The earlier 14 simulation and 13 lint results below were
recorded for `c4d981c`; their RTL/IP/testbench files and expanded Makefile recipes
are unchanged. They were retained rather than rerun. Source, constraints, IP
configuration, benches, and Makefile contents were preserved during this inventory.

| Tool | Observed version |
| --- | --- |
| Icarus Verilog | `13.0 (stable) (v13_0-dirty)`, `/usr/local/bin/iverilog` |
| Verilator | `5.020 2024-01-01 rev (Debian 5.020-1)` |

## Simulation results

The two new targets were rebuilt using `make -B -C sim TARGET`. Both returned
zero, printed `=== ALL TESTS PASSED ===`, and had no runtime failure markers.
Together with the 14 unchanged baseline tests, all 16 targets have passing
results. The first 14 rows are baseline results; the last two are this update.
Icarus emitted warnings about ignored `unique` case qualities and broadened
`always_*` sensitivity; these runs are not warning-free.

| Target | Testbench | Observed coverage | Result |
| --- | --- | --- | --- |
| `sim-mac` | [`tb_mac_addr_table.sv`](../tb/tb_mac_addr_table.sv) | Learn two addresses, hit/miss masks, aging expiration | PASS |
| `sim-bufmgr` | [`tb_buf_mgr_core.sv`](../tb/tb_buf_mgr_core.sv) | Unicast, free-list reuse, multi-destination references, zero-mask drop, concurrent requests | PASS |
| `sim-ingress` | [`tb_ingress_top.sv`](../tb/tb_ingress_top.sv) | Odd-length DDR write, bad-frame drop, two concurrent ingress frames | PASS |
| `sim-egress` | [`tb_egress_top.sv`](../tb/tb_egress_top.sv) | DDR read/stream reconstruction, buffer release, two output ports | PASS |
| `sim-ps-eth` | [`tb_ps_gem_axis_bridge.sv`](../tb/tb_ps_gem_axis_bridge.sv) | RX backpressure/overflow indication, flush suppression, TX pull framing, completion toggle | PASS |
| `sim-integ` | [`tb_egress_gem_tx_integration.sv`](../tb/tb_egress_gem_tx_integration.sv) | Buffer manager + DDR egress + GEM TX adapter; even/odd frame lengths | PASS |
| `sim-async-fifo` | [`tb_async_fifo.sv`](../tb/tb_async_fifo.sv) | Ordering across clocks, full/empty behavior, rejected writes when full, sustained FIFO traffic | PASS |
| `sim-pl-gmii` | [`tb_pl_gmii_adapters.sv`](../tb/tb_pl_gmii_adapters.sv) | Stream adapter round trips for 27-, 14-, and 100-byte frames; does not instantiate the MAC | PASS |
| `sim-sfp-pcs` | [`tb_sfp_1000base_x_pcs.sv`](../tb/tb_sfp_1000base_x_pcs.sv) | 16-bit parallel loopback with related 125/62.5 MHz clocks, sync acquire/loss/recovery, frame/error propagation | PASS |
| `sim-sfp-port` | [`tb_sfp_port_top.sv`](../tb/tb_sfp_port_top.sv) | MAC + PCS + adapters in digital loopback, 73- and 60-byte frames | PASS |
| `sim-cpu-port` | [`tb_cpu_port_top.sv`](../tb/tb_cpu_port_top.sv) | CPU TX into pool, CPU RX from pool, lengths/content and buffer reuse | PASS |
| `sim-mac-fwd` | [`tb_mac_forwarding_top.sv`](../tb/tb_mac_forwarding_top.sv) | Unknown-destination flood, source learning, subsequent targeted hit, short-frame drop | PASS |
| `sim-switch-top` | [`tb_switch_top.sv`](../tb/tb_switch_top.sv) | Assembled switch: 52-byte unknown-destination frame from PS GEM0 reaches CPU egress byte-for-byte | PASS |
| `sim-gth-sim` | [`tb_gth_sfp_sim_model.sv`](../tb/tb_gth_sfp_sim_model.sv) | Behavioral GTH reset/status, ten parallel words with K flags through three-cycle loopback, forced error assertion/clear | PASS |
| `sim-rgmii-sim` | [`tb_rgmii_gmii_sim_model.sv`](../tb/tb_rgmii_gmii_sim_model.sv) | Behavioral RGMII loopback: 20- and 12-byte frames plus error propagation at byte 5 of a 16-byte frame | PASS (new run) |
| `sim-pl-clkgen-sim` | [`tb_pl_eth_clk_gen_sim_model.sv`](../tb/tb_pl_eth_clk_gen_sim_model.sv) | Model lock/startup reset release; measured periods 8 ns, 3.334 ns, 16 ns | PASS (new run) |

The DMA tests use [`axi_mem_bfm.sv`](../tb/axi_mem_bfm.sv), not a real PS DDR
controller. Subsystem tests supply forwarding masks directly; the new
`sim-switch-top` exercises the real parser/table/mask path for a lookup miss.
Its two independent memory BFMs are kept consistent by copying the physical
memory array into the CPU memory array after a write response. That backdoor
copy does not test shared AXI interconnect arbitration or coherency. Learned
unicast is tested in `sim-mac-fwd`, but not yet end-to-end through the switch.

The PCS and SFP-port tests directly loop back decoded parallel symbols. The
GTH behavioral model has its own standalone test and is not instantiated by
those benches. No serial link or optical module participates. GEM tests use
behavioral FIFO stimulus, not the hard GEM.

The RGMII model does not instantiate the hardware adapter, its asynchronous
RX FIFO, or delay/DDR primitives. Its loopback clock is derived from the TX
clock, so it does not validate independent-clock behavior. The clock model
ignores `ref_clk_25m_i` and produces free-running nominal clocks; its 3.334 ns
period is approximately 299.94 MHz. This test does not verify the MMCM,
reference-loss behavior, reset reassertion, calibration, or hardware phase timing.

To repeat the simulation inventory:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port \
    sim-mac-fwd sim-switch-top sim-gth-sim \
    sim-rgmii-sim sim-pl-clkgen-sim
```

Inspect each test's final pass marker and any `FAIL:` messages. Existing tests
use `$finish` on failure as well as success, so process exit status alone is
not a reliable test result. Automated failure propagation remains pending.

## Lint results

The new `lint-pl-clkgen-sim` target passed without warnings. With the unchanged
baseline checks, 11 of 14 lint targets pass. Run them with:

```bash
make -k -C sim lint-mac lint-bufmgr lint-ingress lint-egress \
    lint-ps-eth lint-async-fifo lint-pl-gmii lint-sfp-pcs \
    lint-sfp-port lint-cpu-port lint-mac-fwd lint-switch-top lint-gth-sim \
    lint-pl-clkgen-sim
```

| Target(s) | Result |
| --- | --- |
| `lint-mac`, `lint-bufmgr`, `lint-ingress`, `lint-egress`, `lint-ps-eth`, `lint-async-fifo`, `lint-sfp-pcs`, `lint-cpu-port`, `lint-mac-fwd`, `lint-gth-sim` | PASS, no reported warnings |
| `lint-pl-clkgen-sim` | PASS, no reported warnings (new run) |
| `lint-pl-gmii` | FAIL: Verilator exits due to 31 warnings |
| `lint-sfp-port` | FAIL: Verilator exits due to 36 warnings |
| `lint-switch-top` | FAIL: Verilator exits due to 61 warnings |

All three failing targets report 24 `WIDTHEXPAND` and five `WIDTHTRUNC` warnings
in `open_eth_mac_1g_switch.sv`, plus a `SYMRSVDWORD` warning for `interrupt`.
The remaining warnings are `TIMESCALEMOD`: one for the PL target, six for
the SFP target, and 31 for the switch top. Warnings were not suppressed to
obtain a clean result.

The Makefile also has `lint-integ`, but it selects `egress_top` as the lint
top and does not represent a separately assembled GEM integration wrapper;
it was not counted as another subsystem check.

There is no `lint-rgmii-sim` target: the behavioral RGMII model uses separate
edge-sensitive drivers on the same outputs. Its Makefile explicitly excludes
it from lint. Neither hardware RGMII nor the hardware clock wrapper is covered
by the portable lint targets.

## Not established by these checks

- Complete six-port switch operation or sustained wire-rate performance.
- FreeRTOS operation, CPU-facing vendor AXI DMA, or hardware GEM FIFO timing.
- Real PHY/RGMII or SFP/GTH interoperability and negotiated link operation.
- Synthesis, implementation, resource use, timing closure, physical CDC/reset
  behavior, or MAC XPM memory behavior under `SYNTHESIS`.
- Exhaustive malformed-frame, buffer exhaustion, DMA-error, or reset recovery.

The hardware `gth_sfp_wrapper`, `rgmii_gmii_adapter`, `pl_eth_clk_gen`, and
generated vendor IP were not compiled by these Icarus/Verilator targets.
The source comments report prior GTH elaboration and isolated RGMII/clock
wrapper synthesis in Vivado 2026.1, including clock and pin checks. These are
reported prior checks, not results reproduced here: generation/synthesis scripts
and reports are not committed. They do not establish an integrated implementation.

Documentation checks for this update cover source inventory counts, relative
links, Mermaid syntax, XCI JSON parsing, and unchanged source-file hashes.

XSim targets are available in `sim/Makefile` and currently reference
`/tools/Xilinx/2026.1/Vivado/settings64.sh`. They were not rerun for this
inventory. Existing local XSim databases and simulator binaries are build
artifacts and are excluded from Git.
