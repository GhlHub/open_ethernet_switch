SHELL := /bin/bash
.DEFAULT_GOAL := sim

IP_CATALOG ?= ../build/ip_catalog
.PHONY: verify-ip-flow
verify-ip-flow:
	python3 ../scripts/verify_ip_flow.py

.PHONY: sim-ip-tests sim-ip-tests-packaged check-ip-catalog sim-ip-regression
sim-ip-tests:
	python3 ../scripts/check_ip_tests.py

check-ip-catalog:
	python3 ../scripts/check_ip_catalog.py $(IP_CATALOG)

sim-ip-tests-packaged:
	python3 ../scripts/check_ip_tests.py --catalog $(IP_CATALOG)

sim-ip-regression: sim-ip-tests sim-ip-tests-packaged sim-ip-equivalence

.PHONY: sim-ip-equivalence
sim-ip-equivalence:
	@set -e; for ddr in 0 1; do for debug in 0 1; do \
	  python3 ../scripts/check_ip_equivalence.py --stats-ddr $$ddr --stats-debug $$debug; \
	done; done

MAC_DIR    := ../rtl/mac_table
BUFMGR_DIR := ../rtl/buf_mgr
COMMON_DIR := ../rtl/common
TB_DIR     := ../tb

MAC_SRCS := \
	$(MAC_DIR)/mac_table_pkg.sv \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(MAC_DIR)/mac_table_bank.sv \
	$(MAC_DIR)/bank_arbiter.sv \
	$(MAC_DIR)/aging_sweep_fsm.sv \
	$(MAC_DIR)/learn_engine_fsm.sv \
	$(MAC_DIR)/lookup_engine_fsm.sv \
	$(MAC_DIR)/mac_learn_port.sv \
	$(MAC_DIR)/mac_lookup_port.sv \
	$(MAC_DIR)/mac_addr_table_top.sv

MAC_TB := $(TB_DIR)/tb_mac_addr_table.sv

BUFMGR_SRCS := \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv

BUFMGR_TB := $(TB_DIR)/tb_buf_mgr_core.sv

DMA_DIR := ../rtl/dma

INGRESS_SRCS := \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv \
	$(DMA_DIR)/axi_dma_pkg.sv \
	$(DMA_DIR)/ingress_port_wr.sv \
	$(DMA_DIR)/ingress_dma_wr.sv \
	../ip_repo/switch_fabric/hdl/ingress_datapath.sv \
	$(DMA_DIR)/ingress_top.sv

INGRESS_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_ingress_top.sv

PS_ETH_DIR := ../rtl/ps_eth

PS_ETH_SRCS := \
	$(COMMON_DIR)/sync_fifo.sv \
	$(COMMON_DIR)/async_fifo.sv \
	$(PS_ETH_DIR)/gem_rx_w_to_axis.sv \
	$(PS_ETH_DIR)/axis_to_gem_tx_r.sv \
	$(PS_ETH_DIR)/ps_gem_axis_bridge.sv

PS_ETH_TB := $(TB_DIR)/tb_ps_gem_axis_bridge.sv

EGRESS_SRCS := \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv \
	$(DMA_DIR)/axi_dma_pkg.sv \
	$(DMA_DIR)/egress_port_rd.sv \
	$(DMA_DIR)/egress_dma_rd.sv \
	$(DMA_DIR)/egress_top.sv

EGRESS_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_egress_top.sv

INTEG_SRCS := \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(COMMON_DIR)/async_fifo.sv \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv \
	$(DMA_DIR)/axi_dma_pkg.sv \
	$(DMA_DIR)/egress_port_rd.sv \
	$(DMA_DIR)/egress_dma_rd.sv \
	$(DMA_DIR)/egress_top.sv \
	$(PS_ETH_DIR)/axis_to_gem_tx_r.sv

INTEG_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_egress_gem_tx_integration.sv

SFP_PCS_DIR := ../rtl/sfp_pcs

SFP_PCS_SRCS := \
	$(SFP_PCS_DIR)/sfp_pcs_pkg.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_tx.sv \
	$(SFP_PCS_DIR)/sync_1000base_x.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_rx.sv \
	$(SFP_PCS_DIR)/autoneg_1000base_x.sv \
	$(SFP_PCS_DIR)/sfp_1000base_x_pcs.sv

SFP_PCS_TB := $(TB_DIR)/tb_sfp_1000base_x_pcs.sv

AUTONEG_TB := $(TB_DIR)/tb_autoneg_1000base_x.sv

ASYNC_FIFO_SRCS := $(COMMON_DIR)/async_fifo.sv
ASYNC_FIFO_TB   := $(TB_DIR)/tb_async_fifo.sv

PL_GMII_DIR := ../rtl/pl_gmii

PL_GMII_SRCS := ../rtl/stats/stats_bank.sv \
	$(COMMON_DIR)/async_fifo.sv \
	$(PL_GMII_DIR)/open_eth_mac_1g_switch.sv \
	$(PL_GMII_DIR)/mac_rxd_to_switch_ingress.sv \
	$(PL_GMII_DIR)/switch_egress_to_mac_txd.sv \
	$(PL_GMII_DIR)/pl_gmii_mac_top.sv

# adapter-only sources for the standalone round-trip testbench, which
# does not instantiate the third-party MAC core (see tb_pl_gmii_adapters.sv)
PL_GMII_ADAPT_SRCS := \
	$(COMMON_DIR)/async_fifo.sv \
	$(PL_GMII_DIR)/mac_rxd_to_switch_ingress.sv \
	$(PL_GMII_DIR)/switch_egress_to_mac_txd.sv

PL_GMII_TB := $(TB_DIR)/tb_pl_gmii_adapters.sv

MAC_RESET_SRCS := ../rtl/stats/stats_bank.sv $(PL_GMII_DIR)/open_eth_mac_1g_switch.sv
MAC_RESET_TB   := $(TB_DIR)/tb_mac_reset_reclock.sv

SFP_PORT_SRCS := ../rtl/stats/stats_bank.sv \
	$(COMMON_DIR)/async_fifo.sv \
	$(SFP_PCS_DIR)/sfp_pcs_pkg.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_tx.sv \
	$(SFP_PCS_DIR)/sync_1000base_x.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_rx.sv \
	$(SFP_PCS_DIR)/autoneg_1000base_x.sv \
	$(SFP_PCS_DIR)/sfp_1000base_x_pcs.sv \
	$(PL_GMII_DIR)/open_eth_mac_1g_switch.sv \
	$(PL_GMII_DIR)/mac_rxd_to_switch_ingress.sv \
	$(PL_GMII_DIR)/switch_egress_to_mac_txd.sv \
	$(SFP_PCS_DIR)/sfp_port_top.sv

SFP_PORT_TB := $(TB_DIR)/tb_sfp_port_top.sv

CPU_PORT_DIR := ../rtl/cpu_port

CPU_PORT_SRCS := \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv \
	$(DMA_DIR)/axi_dma_pkg.sv \
	$(DMA_DIR)/ingress_port_wr.sv \
	$(DMA_DIR)/egress_port_rd.sv \
	$(CPU_PORT_DIR)/cpu_dma_wr.sv \
	$(CPU_PORT_DIR)/cpu_dma_rd.sv \
	$(CPU_PORT_DIR)/cpu_port_top.sv

CPU_PORT_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_cpu_port_top.sv

MAC_FWD_SRCS := \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(MAC_SRCS) \
	$(MAC_DIR)/mac_addr_resolver.sv \
	$(MAC_DIR)/mac_forwarding_top.sv

MAC_FWD_TB := $(TB_DIR)/tb_mac_forwarding_top.sv

# The IP manifests are shared with packaging and the board build.
SWITCH_TOP_SRCS := $(shell python3 ../scripts/ip_sources.py --assembly)

SWITCH_TOP_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_switch_top.sv

GTH_SIM_SRCS := $(SFP_PCS_DIR)/gth_sfp_sim_model.sv
GTH_SIM_TB   := $(TB_DIR)/tb_gth_sfp_sim_model.sv

RGMII_SIM_SRCS := $(PL_GMII_DIR)/rgmii_gmii_sim_model.sv
RGMII_SIM_TB   := $(TB_DIR)/tb_rgmii_gmii_sim_model.sv

PL_CLKGEN_SIM_SRCS := $(PL_GMII_DIR)/pl_eth_clk_gen_sim_model.sv
PL_CLKGEN_SIM_TB   := $(TB_DIR)/tb_pl_eth_clk_gen_sim_model.sv

MDIO_DIR := ../rtl/mdio
MDIO_SIM_SRCS := $(MDIO_DIR)/open_eth_mdio_master.sv $(MDIO_DIR)/phy_init_seq.sv $(MDIO_DIR)/mdio_controller_sim_model.sv
MDIO_SIM_TB   := $(TB_DIR)/tb_mdio_controller.sv

VIVADO_SETTINGS := /tools/Xilinx/2026.1/Vivado/settings64.sh

.PHONY: sim-mac-reset xsim-mac-reset xsim-async-fifo-xpm xsim-ps-eth-xpm xsim-pl-gmii-xpm xsim-integ-xpm sim lint xsim sim-mac lint-mac xsim-mac sim-bufmgr lint-bufmgr xsim-bufmgr sim-ingress lint-ingress xsim-ingress sim-ps-eth lint-ps-eth xsim-ps-eth sim-egress lint-egress xsim-egress sim-integ lint-integ xsim-integ sim-sfp-pcs lint-sfp-pcs xsim-sfp-pcs sim-autoneg lint-autoneg xsim-autoneg sim-async-fifo lint-async-fifo xsim-async-fifo sim-pl-gmii lint-pl-gmii sim-sfp-port lint-sfp-port sim-cpu-port lint-cpu-port sim-mac-fwd lint-mac-fwd sim-switch-top lint-switch-top sim-gth-sim lint-gth-sim xsim-gth-sim sim-rgmii-sim xsim-rgmii-sim sim-pl-clkgen-sim lint-pl-clkgen-sim xsim-pl-clkgen-sim sim-mdio lint-mdio xsim-mdio clean

# default targets operate on the MAC table, for backwards compatibility
sim: sim-mac
lint: lint-mac
xsim: xsim-mac

sim-mac: tb_mac_addr_table.vvp
	vvp tb_mac_addr_table.vvp

tb_mac_addr_table.vvp: $(MAC_SRCS) $(MAC_TB)
	iverilog -g2012 -o $@ $(MAC_SRCS) $(MAC_TB)

lint-mac:
	verilator --lint-only --top-module mac_addr_table_top $(MAC_SRCS)

xsim-mac:
	mkdir -p xsim_run_mac
	cd xsim_run_mac && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(MAC_SRCS)) $(addprefix ../,$(MAC_TB)) && \
	  xelab -debug typical tb_mac_addr_table -s tb_sim && \
	  xsim tb_sim -runall

sim-bufmgr: tb_buf_mgr_core.vvp
	vvp tb_buf_mgr_core.vvp

tb_buf_mgr_core.vvp: $(BUFMGR_SRCS) $(BUFMGR_TB)
	iverilog -g2012 -o $@ $(BUFMGR_SRCS) $(BUFMGR_TB)

lint-bufmgr:
	verilator --lint-only --top-module buf_mgr_core $(BUFMGR_SRCS)

xsim-bufmgr:
	mkdir -p xsim_run_bufmgr
	cd xsim_run_bufmgr && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(BUFMGR_SRCS)) $(addprefix ../,$(BUFMGR_TB)) && \
	  xelab -debug typical tb_buf_mgr_core -s tb_sim && \
	  xsim tb_sim -runall

sim-ingress: tb_ingress_top.vvp
	vvp tb_ingress_top.vvp

tb_ingress_top.vvp: $(INGRESS_SRCS) $(INGRESS_TB)
	iverilog -g2012 -o $@ $(INGRESS_SRCS) $(INGRESS_TB)

lint-ingress:
	verilator --lint-only --top-module ingress_top $(INGRESS_SRCS)

xsim-ingress:
	mkdir -p xsim_run_ingress
	cd xsim_run_ingress && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(INGRESS_SRCS)) $(addprefix ../,$(INGRESS_TB)) && \
	  xelab -debug typical tb_ingress_top -s tb_sim && \
	  xsim tb_sim -runall

sim-ps-eth: tb_ps_gem_axis_bridge.vvp
	vvp tb_ps_gem_axis_bridge.vvp

tb_ps_gem_axis_bridge.vvp: $(PS_ETH_SRCS) $(PS_ETH_TB)
	iverilog -g2012 -o $@ $(PS_ETH_SRCS) $(PS_ETH_TB)

lint-ps-eth:
	verilator --lint-only --top-module ps_gem_axis_bridge $(PS_ETH_SRCS)

xsim-ps-eth:
	mkdir -p xsim_run_ps_eth
	cd xsim_run_ps_eth && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(PS_ETH_SRCS)) $(addprefix ../,$(PS_ETH_TB)) && \
	  xelab -debug typical tb_ps_gem_axis_bridge -s tb_sim && \
	  xsim tb_sim -runall

sim-egress: tb_egress_top.vvp
	vvp tb_egress_top.vvp

tb_egress_top.vvp: $(EGRESS_SRCS) $(EGRESS_TB)
	iverilog -g2012 -o $@ $(EGRESS_SRCS) $(EGRESS_TB)

lint-egress:
	verilator --lint-only --top-module egress_top $(EGRESS_SRCS)

xsim-egress:
	mkdir -p xsim_run_egress
	cd xsim_run_egress && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(EGRESS_SRCS)) $(addprefix ../,$(EGRESS_TB)) && \
	  xelab -debug typical tb_egress_top -s tb_sim && \
	  xsim tb_sim -runall

sim-integ: tb_egress_gem_tx_integration.vvp
	vvp tb_egress_gem_tx_integration.vvp

tb_egress_gem_tx_integration.vvp: $(INTEG_SRCS) $(INTEG_TB)
	iverilog -g2012 -o $@ $(INTEG_SRCS) $(INTEG_TB)

lint-integ:
	verilator --lint-only --top-module egress_top $(INTEG_SRCS)

xsim-integ:
	mkdir -p xsim_run_integ
	cd xsim_run_integ && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(INTEG_SRCS)) $(addprefix ../,$(INTEG_TB)) && \
	  xelab -debug typical tb_egress_gem_tx_integration -s tb_sim && \
	  xsim tb_sim -runall

.PHONY: sim-sfp-pcs-phases
sim-sfp-pcs-phases:
	@set -e; for phase in 4 8 12 16; do for shift in 0 1; do \
	  echo "PCS GTH first edge: $$phase ns, RX byte shift: $$shift"; \
	  iverilog -g2012 -s tb_sfp_1000base_x_pcs -Ptb_sfp_1000base_x_pcs.GTH_FIRST_EDGE_NS=$$phase -Ptb_sfp_1000base_x_pcs.RX_BYTE_SHIFT=$$shift -o tb_sfp_pcs_phase.vvp $(SFP_PCS_SRCS) $(SFP_PCS_TB); \
	  vvp tb_sfp_pcs_phase.vvp; \
	done; done

sim-sfp-pcs: tb_sfp_1000base_x_pcs.vvp
	vvp tb_sfp_1000base_x_pcs.vvp

tb_sfp_1000base_x_pcs.vvp: $(SFP_PCS_SRCS) $(SFP_PCS_TB)
	iverilog -g2012 -o $@ $(SFP_PCS_SRCS) $(SFP_PCS_TB)

lint-sfp-pcs:
	verilator --lint-only --top-module sfp_1000base_x_pcs $(SFP_PCS_SRCS)

xsim-sfp-pcs:
	mkdir -p xsim_run_sfp_pcs
	cd xsim_run_sfp_pcs && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(SFP_PCS_SRCS)) $(addprefix ../,$(SFP_PCS_TB)) && \
	  xelab -debug typical tb_sfp_1000base_x_pcs -s tb_sim && \
	  xsim tb_sim -runall

sim-autoneg: tb_autoneg_1000base_x.vvp
	vvp tb_autoneg_1000base_x.vvp

tb_autoneg_1000base_x.vvp: $(SFP_PCS_SRCS) $(AUTONEG_TB)
	iverilog -g2012 -o $@ $(SFP_PCS_SRCS) $(AUTONEG_TB)

lint-autoneg:
	verilator --lint-only --top-module autoneg_1000base_x $(SFP_PCS_SRCS)

xsim-autoneg:
	mkdir -p xsim_run_autoneg
	cd xsim_run_autoneg && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(SFP_PCS_SRCS)) $(addprefix ../,$(AUTONEG_TB)) && \
	  xelab -debug typical tb_autoneg_1000base_x -s tb_sim && \
	  xsim tb_sim -runall

sim-mac-reset: tb_mac_reset_reclock.vvp
	vvp tb_mac_reset_reclock.vvp

tb_mac_reset_reclock.vvp: $(MAC_RESET_SRCS) $(MAC_RESET_TB)
	iverilog -g2012 -o $@ $(MAC_RESET_SRCS) $(MAC_RESET_TB)

xsim-mac-reset:
	mkdir -p xsim_run_mac_reset
	cd xsim_run_mac_reset && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(MAC_RESET_SRCS)) $(addprefix ../,$(MAC_RESET_TB)) && \
	  xelab -debug typical tb_mac_reset_reclock -s tb_sim && \
	  xsim tb_sim -runall

sim-async-fifo: tb_async_fifo.vvp
	vvp tb_async_fifo.vvp

tb_async_fifo.vvp: $(ASYNC_FIFO_SRCS) $(ASYNC_FIFO_TB)
	iverilog -g2012 -o $@ $(ASYNC_FIFO_SRCS) $(ASYNC_FIFO_TB)

lint-async-fifo:
	verilator --lint-only --top-module async_fifo $(ASYNC_FIFO_SRCS)

xsim-async-fifo:
	mkdir -p xsim_run_async_fifo
	cd xsim_run_async_fifo && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(ASYNC_FIFO_SRCS)) $(addprefix ../,$(ASYNC_FIFO_TB)) && \
	  xelab -debug typical tb_async_fifo -s tb_sim && \
	  xsim tb_sim -runall

# The same testbench against the XPM (xpm_fifo_async) path: Vivado xsim with
# SYNTHESIS defined, XPM library and glbl linked. This is the only simulator
# that can run the synthesis-side async_fifo.
xsim-async-fifo-xpm:
	mkdir -p xsim_run_async_fifo_xpm
	cd xsim_run_async_fifo_xpm && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS $(addprefix ../,$(ASYNC_FIFO_SRCS)) $(addprefix ../,$(ASYNC_FIFO_TB)) && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L xpm tb_async_fifo glbl -s tb_sim && \
	  xsim tb_sim -runall

# Bridge and adapter benches against the XPM async FIFO (see xsim-async-fifo-xpm).
xsim-ps-eth-xpm:
	mkdir -p xsim_run_ps_eth_xpm
	cd xsim_run_ps_eth_xpm && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS $(addprefix ../,$(PS_ETH_SRCS)) $(addprefix ../,$(PS_ETH_TB)) && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L xpm tb_ps_gem_axis_bridge glbl -s tb_sim && \
	  xsim tb_sim -runall

xsim-integ-xpm:
	mkdir -p xsim_run_integ_xpm
	cd xsim_run_integ_xpm && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS $(addprefix ../,$(INTEG_SRCS)) $(addprefix ../,$(INTEG_TB)) && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L xpm tb_egress_gem_tx_integration glbl -s tb_sim && \
	  xsim tb_sim -runall

xsim-pl-gmii-xpm:
	mkdir -p xsim_run_pl_gmii_xpm
	cd xsim_run_pl_gmii_xpm && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS $(addprefix ../,$(PL_GMII_ADAPT_SRCS)) $(addprefix ../,$(PL_GMII_TB)) && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L xpm tb_pl_gmii_adapters glbl -s tb_sim && \
	  xsim tb_sim -runall

sim-pl-gmii: tb_pl_gmii_adapters.vvp
	vvp tb_pl_gmii_adapters.vvp

tb_pl_gmii_adapters.vvp: $(PL_GMII_ADAPT_SRCS) $(PL_GMII_TB)
	iverilog -g2012 -o $@ $(PL_GMII_ADAPT_SRCS) $(PL_GMII_TB)

# lints the full port (third-party MAC core + both adapters + top wrapper)
lint-pl-gmii:
	verilator --lint-only --timing --top-module pl_gmii_mac_top $(PL_GMII_SRCS)

xsim-pl-gmii:
	mkdir -p xsim_run_pl_gmii
	cd xsim_run_pl_gmii && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(PL_GMII_ADAPT_SRCS)) $(addprefix ../,$(PL_GMII_TB)) && \
	  xelab -debug typical tb_pl_gmii_adapters -s tb_sim && \
	  xsim tb_sim -runall

sim-sfp-port: tb_sfp_port_top.vvp
	vvp tb_sfp_port_top.vvp

tb_sfp_port_top.vvp: $(SFP_PORT_SRCS) $(SFP_PORT_TB)
	iverilog -g2012 -o $@ $(SFP_PORT_SRCS) $(SFP_PORT_TB)

lint-sfp-port:
	verilator --lint-only --timing --top-module sfp_port_top $(SFP_PORT_SRCS)

xsim-sfp-port:
	mkdir -p xsim_run_sfp_port
	cd xsim_run_sfp_port && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(SFP_PORT_SRCS)) $(addprefix ../,$(SFP_PORT_TB)) && \
	  xelab -debug typical tb_sfp_port_top -s tb_sim && \
	  xsim tb_sim -runall

sim-cpu-port: tb_cpu_port_top.vvp
	vvp tb_cpu_port_top.vvp

tb_cpu_port_top.vvp: $(CPU_PORT_SRCS) $(CPU_PORT_TB)
	iverilog -g2012 -o $@ $(CPU_PORT_SRCS) $(CPU_PORT_TB)

lint-cpu-port:
	verilator --lint-only --top-module cpu_port_top $(CPU_PORT_SRCS)

xsim-cpu-port:
	mkdir -p xsim_run_cpu_port
	cd xsim_run_cpu_port && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(CPU_PORT_SRCS)) $(addprefix ../,$(CPU_PORT_TB)) && \
	  xelab -debug typical tb_cpu_port_top -s tb_sim && \
	  xsim tb_sim -runall

sim-mac-fwd: tb_mac_forwarding_top.vvp
	vvp tb_mac_forwarding_top.vvp

tb_mac_forwarding_top.vvp: $(MAC_FWD_SRCS) $(MAC_FWD_TB)
	iverilog -g2012 -o $@ $(MAC_FWD_SRCS) $(MAC_FWD_TB)

lint-mac-fwd:
	verilator --lint-only --top-module mac_forwarding_top $(MAC_FWD_SRCS)

xsim-mac-fwd:
	mkdir -p xsim_run_mac_fwd
	cd xsim_run_mac_fwd && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(MAC_FWD_SRCS)) $(addprefix ../,$(MAC_FWD_TB)) && \
	  xelab -debug typical tb_mac_forwarding_top -s tb_sim && \
	  xsim tb_sim -runall

sim-switch-top: tb_switch_top.vvp
	vvp tb_switch_top.vvp

tb_switch_top.vvp: $(SWITCH_TOP_SRCS) $(SWITCH_TOP_TB)
	iverilog -g2012 -o $@ $(SWITCH_TOP_SRCS) $(SWITCH_TOP_TB)

lint-switch-top:
	verilator --lint-only --timing --top-module switch_top $(SWITCH_TOP_SRCS)

xsim-switch-top:
	mkdir -p xsim_run_switch_top
	cd xsim_run_switch_top && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(SWITCH_TOP_SRCS)) $(addprefix ../,$(SWITCH_TOP_TB)) && \
	  xelab -debug typical tb_switch_top -s tb_sim && \
	  xsim tb_sim -runall

sim-gth-sim: tb_gth_sfp_sim_model.vvp
	vvp tb_gth_sfp_sim_model.vvp

tb_gth_sfp_sim_model.vvp: $(GTH_SIM_SRCS) $(GTH_SIM_TB)
	iverilog -g2012 -o $@ $(GTH_SIM_SRCS) $(GTH_SIM_TB)

lint-gth-sim:
	verilator --lint-only --timing --top-module gth_sfp_sim_model $(GTH_SIM_SRCS)

xsim-gth-sim:
	mkdir -p xsim_run_gth_sim
	cd xsim_run_gth_sim && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(GTH_SIM_SRCS)) $(addprefix ../,$(GTH_SIM_TB)) && \
	  xelab -debug typical tb_gth_sfp_sim_model -s tb_sim && \
	  xsim tb_sim -runall

RX_ELASTIC_SRCS := $(COMMON_DIR)/fifo36_async_2kx18.sv $(PL_GMII_DIR)/rgmii_rx_elastic.sv
RX_ELASTIC_TB   := $(TB_DIR)/tb_rgmii_rx_elastic.sv

.PHONY: xsim-rgmii-idelay-gate
xsim-rgmii-idelay-gate:
	mkdir -p xsim_run_idelay_gate
	cd xsim_run_idelay_gate && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS ../../rtl/common/fifo36_async_2kx18.sv ../../rtl/common/sticky_xdomain.sv ../../rtl/pl_gmii/rgmii_rx_elastic.sv ../../rtl/pl_gmii/rgmii_gmii_adapter.sv ../../tb/tb_rgmii_idelay_gate.sv && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L unisims_ver tb_rgmii_idelay_gate glbl -s tb_sim && \
	  xsim tb_sim -runall

.PHONY: sim-mac-adapters
sim-mac-adapters: $(COMMON_DIR)/async_fifo.sv $(PL_GMII_DIR)/mac_rxd_to_switch_ingress.sv $(PL_GMII_DIR)/switch_egress_to_mac_txd.sv $(TB_DIR)/tb_mac_adapters.sv
	iverilog -g2012 -o tb_mac_adapters.vvp $^ && vvp tb_mac_adapters.vvp | grep "PASS\|FAIL\|INFO"

.PHONY: sim-pl-linerate
sim-pl-linerate: $(PL_GMII_SRCS) $(TB_DIR)/tb_pl_mac_linerate.sv
	iverilog -g2012 -o tb_pl_mac_linerate.vvp $^ && vvp tb_pl_mac_linerate.vvp | grep "PASS\|FAIL\|INFO"

.PHONY: sim-rx-diag
sim-rx-diag: ../rtl/common/sticky_xdomain.sv ../rtl/board/rx_diag_regs.sv $(TB_DIR)/tb_rx_diag.sv ../rtl/sfp_pcs/sfp_sideband.sv $(TB_DIR)/tb_sfp_sideband.sv
	iverilog -g2012 -s tb_rx_diag -o tb_rx_diag.vvp ../rtl/common/sticky_xdomain.sv ../rtl/board/rx_diag_regs.sv $(TB_DIR)/tb_rx_diag.sv && vvp tb_rx_diag.vvp | grep "PASS\|FAIL"
	iverilog -g2012 -s tb_sfp_sideband -o tb_sfp_sideband.vvp ../rtl/sfp_pcs/sfp_sideband.sv $(TB_DIR)/tb_sfp_sideband.sv && vvp tb_sfp_sideband.vvp | grep "PASS\|FAIL"

.PHONY: sim-rx-elastic xsim-rx-elastic-hw
sim-rx-elastic: $(RX_ELASTIC_SRCS) $(RX_ELASTIC_TB)
	for p in 500 -500 0 3000 -3000; do \
	  iverilog -g2012 -Ptb_rgmii_rx_elastic.PPM=$$p -o tb_rgmii_rx_elastic.vvp $(RX_ELASTIC_SRCS) $(RX_ELASTIC_TB) && \
	  vvp tb_rgmii_rx_elastic.vvp | grep "PPM\|PASS\|FAIL" || exit 1; \
	done

# same bench against the real FIFO36E2 (unisim model) in Vivado xsim
xsim-rx-elastic-hw:
	mkdir -p xsim_run_rx_elastic
	cd xsim_run_rx_elastic && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv -d SYNTHESIS $(addprefix ../,$(RX_ELASTIC_SRCS)) $(addprefix ../,$(RX_ELASTIC_TB)) && \
	  xvlog $$XILINX_VIVADO/data/verilog/src/glbl.v && \
	  xelab -debug typical -L unisims_ver -generic_top PPM=500 tb_rgmii_rx_elastic glbl -s tb_sim && \
	  xsim tb_sim -runall

sim-rgmii-sim: tb_rgmii_gmii_sim_model.vvp
	vvp tb_rgmii_gmii_sim_model.vvp

tb_rgmii_gmii_sim_model.vvp: $(RGMII_SIM_SRCS) $(RGMII_SIM_TB)
	iverilog -g2012 -o $@ $(RGMII_SIM_SRCS) $(RGMII_SIM_TB)

# no lint-rgmii-sim target: this model is a deliberately non-synthesizable
# dual-edge behavioral stand-in (see rgmii_gmii_sim_model.sv's own header)

xsim-rgmii-sim:
	mkdir -p xsim_run_rgmii_sim
	cd xsim_run_rgmii_sim && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(RGMII_SIM_SRCS)) $(addprefix ../,$(RGMII_SIM_TB)) && \
	  xelab -debug typical tb_rgmii_gmii_sim_model -s tb_sim && \
	  xsim tb_sim -runall

sim-pl-clkgen-sim: tb_pl_eth_clk_gen_sim_model.vvp
	vvp tb_pl_eth_clk_gen_sim_model.vvp

tb_pl_eth_clk_gen_sim_model.vvp: $(PL_CLKGEN_SIM_SRCS) $(PL_CLKGEN_SIM_TB)
	iverilog -g2012 -o $@ $(PL_CLKGEN_SIM_SRCS) $(PL_CLKGEN_SIM_TB)

lint-pl-clkgen-sim:
	verilator --lint-only --timing --top-module pl_eth_clk_gen_sim_model $(PL_CLKGEN_SIM_SRCS)

xsim-pl-clkgen-sim:
	mkdir -p xsim_run_pl_clkgen_sim
	cd xsim_run_pl_clkgen_sim && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(PL_CLKGEN_SIM_SRCS)) $(addprefix ../,$(PL_CLKGEN_SIM_TB)) && \
	  xelab -debug typical tb_pl_eth_clk_gen_sim_model -s tb_sim && \
	  xsim tb_sim -runall

sim-mdio: tb_mdio_controller.vvp tb_phy_init_seq.vvp tb_mac_reset_reclock.vvp
	vvp tb_mdio_controller.vvp
	vvp tb_phy_init_seq.vvp

tb_phy_init_seq.vvp: $(MDIO_SIM_SRCS) $(TB_DIR)/tb_phy_init_seq.sv
	iverilog -g2012 -o $@ $(MDIO_SIM_SRCS) $(TB_DIR)/tb_phy_init_seq.sv

tb_mdio_controller.vvp: $(MDIO_SIM_SRCS) $(MDIO_SIM_TB)
	iverilog -g2012 -o $@ $(MDIO_SIM_SRCS) $(MDIO_SIM_TB)

lint-mdio:
	verilator --lint-only --timing --top-module mdio_controller_sim_model $(MDIO_SIM_SRCS)

xsim-mdio:
	mkdir -p xsim_run_mdio xsim_run_mac_reset
	cd xsim_run_mdio && \
	  source $(VIVADO_SETTINGS) && \
	  xvlog -sv $(addprefix ../,$(MDIO_SIM_SRCS)) $(addprefix ../,$(MDIO_SIM_TB)) && \
	  xelab -debug typical tb_mdio_controller -s tb_sim && \
	  xsim tb_sim -runall

clean:
	rm -f tb_cpu_dma_pipeline.vvp tb_mac_addr_table.vvp tb_buf_mgr_core.vvp tb_ingress_top.vvp tb_ps_gem_axis_bridge.vvp tb_egress_top.vvp tb_egress_gem_tx_integration.vvp tb_sfp_1000base_x_pcs.vvp tb_autoneg_1000base_x.vvp tb_async_fifo.vvp tb_pl_gmii_adapters.vvp tb_sfp_port_top.vvp tb_cpu_port_top.vvp tb_mac_forwarding_top.vvp tb_switch_top.vvp tb_gth_sfp_sim_model.vvp tb_rgmii_gmii_sim_model.vvp tb_pl_eth_clk_gen_sim_model.vvp tb_mdio_controller.vvp tb_phy_init_seq.vvp tb_mac_reset_reclock.vvp
	rm -rf xsim_run_idelay_gate xsim_run_rx_elastic tb_rgmii_rx_elastic.vvp xsim_run xsim_run_mac xsim_run_bufmgr xsim_run_ingress xsim_run_ps_eth xsim_run_egress xsim_run_integ xsim_run_sfp_pcs xsim_run_autoneg xsim_run_async_fifo xsim_run_async_fifo_xpm xsim_run_ps_eth_xpm xsim_run_integ_xpm xsim_run_pl_gmii_xpm xsim_run_pl_gmii xsim_run_sfp_port xsim_run_cpu_port xsim_run_mac_fwd xsim_run_switch_top xsim_run_gth_sim xsim_run_rgmii_sim xsim_run_pl_clkgen_sim xsim_run_mdio

# Check real wrapper wiring against the GTH decoded RX control-port contract.
.PHONY: sim-gth-rx-mapping
sim-gth-rx-mapping:
	iverilog -g2012 -s tb_gth_rx_mapping -o tb_gth_rx_mapping.vvp ../rtl/sfp_pcs/gth_sfp_wrapper.sv $(TB_DIR)/tb_gth_rx_mapping.sv
	vvp tb_gth_rx_mapping.vvp

.PHONY: sim-autoneg-clock-correction
sim-autoneg-clock-correction:
	iverilog -g2012 -s tb_autoneg_clock_correction -o tb_autoneg_clock_correction.vvp $(SFP_PCS_DIR)/sfp_pcs_pkg.sv $(SFP_PCS_DIR)/autoneg_1000base_x.sv $(TB_DIR)/tb_autoneg_clock_correction.sv
	vvp tb_autoneg_clock_correction.vvp

.PHONY: sim-sfp-rx-preamble
sim-sfp-rx-preamble:
	iverilog -g2012 -s tb_sfp_rx_preamble -o tb_sfp_rx_preamble.vvp $(SFP_PCS_DIR)/sfp_pcs_pkg.sv $(SFP_PCS_DIR)/gmii_1000base_x_rx.sv $(TB_DIR)/tb_sfp_rx_preamble.sv
	vvp tb_sfp_rx_preamble.vvp

.PHONY: sim-sfp-tx-alignment
sim-sfp-tx-alignment:
	iverilog -g2012 -s tb_sfp_tx_alignment -o tb_sfp_tx_alignment.vvp $(SFP_PCS_DIR)/sfp_pcs_pkg.sv $(SFP_PCS_DIR)/gmii_1000base_x_tx.sv $(TB_DIR)/tb_sfp_tx_alignment.sv
	vvp tb_sfp_tx_alignment.vvp

.PHONY: sim-sfp-tx-idle
sim-sfp-tx-idle:
	iverilog -g2012 -s tb_sfp_tx_idle -o tb_sfp_tx_idle.vvp $(SFP_PCS_SRCS) $(TB_DIR)/tb_sfp_tx_idle.sv
	vvp tb_sfp_tx_idle.vvp

.PHONY: sim-statistics
sim-statistics:
	iverilog -g2012 -s tb_statistics -o tb_statistics.vvp ../rtl/stats/stats_bank.sv ../rtl/board/rx_diag_regs.sv $(TB_DIR)/tb_statistics.sv
	vvp tb_statistics.vvp
	iverilog -g2012 -s tb_statistics_axi -o tb_statistics_axi.vvp ../rtl/stats/stats_bank.sv ../rtl/stats/stats_axi.sv $(TB_DIR)/tb_statistics_axi.sv
	vvp tb_statistics_axi.vvp
	iverilog -g2012 -s tb_statistics_ports -o tb_statistics_ports.vvp ../rtl/stats/stats_gem.sv ../rtl/stats/stats_axis.sv $(TB_DIR)/tb_statistics_ports.sv
	vvp tb_statistics_ports.vvp

.PHONY: sim-ingress-pipeline
sim-ingress-pipeline: tb_ingress_dma_pipeline.vvp
	vvp $<

tb_ingress_dma_pipeline.vvp: $(BUFMGR_DIR)/buf_mgr_pkg.sv $(DMA_DIR)/axi_dma_pkg.sv $(COMMON_DIR)/rr_arbiter.sv $(DMA_DIR)/ingress_dma_wr.sv $(TB_DIR)/tb_ingress_dma_pipeline.sv
	iverilog -g2012 -s tb_ingress_dma_pipeline -o $@ $^

.PHONY: sim-ingress-pipeline-verilator
sim-ingress-pipeline-verilator: $(BUFMGR_DIR)/buf_mgr_pkg.sv $(DMA_DIR)/axi_dma_pkg.sv $(COMMON_DIR)/rr_arbiter.sv $(DMA_DIR)/ingress_dma_wr.sv $(TB_DIR)/tb_ingress_dma_pipeline.sv
	mkdir -p obj_dir/ingress_pipeline
	verilator --binary --timing -Wno-TIMESCALEMOD --top-module tb_ingress_dma_pipeline --Mdir obj_dir/ingress_pipeline -j 4 $^
	./obj_dir/ingress_pipeline/Vtb_ingress_dma_pipeline

# Same self-checking bridge tests with 125/25/2.5 MHz GEM clocks.
.PHONY: sim-ps-eth-multirate
sim-ps-eth-multirate:
	@set -e; for half in 4 20 200; do \
	  iverilog -g2012 -s tb_ps_gem_axis_bridge -Ptb_ps_gem_axis_bridge.GEM_HALF_NS=$$half -o tb_ps_gem_multirate.vvp $(PS_ETH_SRCS) $(PS_ETH_TB); \
	  vvp tb_ps_gem_multirate.vvp > ps_multirate_$$half.log; \
	  cat ps_multirate_$$half.log; \
	  ! grep -Eq 'FAIL|FATAL|ERROR' ps_multirate_$$half.log; \
	done

.PHONY: sim-cpu-pipeline sim-cpu-pipeline-verilator
sim-cpu-pipeline: tb_cpu_dma_pipeline.vvp
	vvp $<

tb_cpu_dma_pipeline.vvp: $(BUFMGR_DIR)/buf_mgr_pkg.sv $(DMA_DIR)/axi_dma_pkg.sv $(CPU_PORT_DIR)/cpu_dma_wr.sv $(TB_DIR)/tb_cpu_dma_pipeline.sv
	iverilog -g2012 -s tb_cpu_dma_pipeline -o $@ $^

sim-cpu-pipeline-verilator: $(BUFMGR_DIR)/buf_mgr_pkg.sv $(DMA_DIR)/axi_dma_pkg.sv $(CPU_PORT_DIR)/cpu_dma_wr.sv $(TB_DIR)/tb_cpu_dma_pipeline.sv
	mkdir -p obj_dir/cpu_pipeline
	verilator --binary --timing -Wno-TIMESCALEMOD --top-module tb_cpu_dma_pipeline --Mdir obj_dir/cpu_pipeline -j 4 $^
	./obj_dir/cpu_pipeline/Vtb_cpu_dma_pipeline
