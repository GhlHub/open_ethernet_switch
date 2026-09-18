SHELL := /bin/bash

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
	$(SFP_PCS_DIR)/sfp_1000base_x_pcs.sv

SFP_PCS_TB := $(TB_DIR)/tb_sfp_1000base_x_pcs.sv

ASYNC_FIFO_SRCS := $(COMMON_DIR)/async_fifo.sv
ASYNC_FIFO_TB   := $(TB_DIR)/tb_async_fifo.sv

PL_GMII_DIR := ../rtl/pl_gmii

PL_GMII_SRCS := \
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

SFP_PORT_SRCS := \
	$(COMMON_DIR)/async_fifo.sv \
	$(SFP_PCS_DIR)/sfp_pcs_pkg.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_tx.sv \
	$(SFP_PCS_DIR)/sync_1000base_x.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_rx.sv \
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

SWITCH_TOP_SRCS := \
	$(BUFMGR_DIR)/buf_mgr_pkg.sv \
	$(MAC_DIR)/mac_table_pkg.sv \
	$(DMA_DIR)/axi_dma_pkg.sv \
	$(COMMON_DIR)/rr_arbiter.sv \
	$(COMMON_DIR)/sync_fifo.sv \
	$(COMMON_DIR)/async_fifo.sv \
	$(BUFMGR_DIR)/free_list_mgr.sv \
	$(BUFMGR_DIR)/queue_mgr.sv \
	$(BUFMGR_DIR)/buf_mgr_core.sv \
	$(DMA_DIR)/ingress_port_wr.sv \
	$(DMA_DIR)/ingress_dma_wr.sv \
	$(DMA_DIR)/ingress_top.sv \
	$(DMA_DIR)/egress_port_rd.sv \
	$(DMA_DIR)/egress_dma_rd.sv \
	$(DMA_DIR)/egress_top.sv \
	$(CPU_PORT_DIR)/cpu_dma_wr.sv \
	$(CPU_PORT_DIR)/cpu_dma_rd.sv \
	$(CPU_PORT_DIR)/cpu_port_top.sv \
	$(MAC_DIR)/mac_table_bank.sv \
	$(MAC_DIR)/bank_arbiter.sv \
	$(MAC_DIR)/aging_sweep_fsm.sv \
	$(MAC_DIR)/learn_engine_fsm.sv \
	$(MAC_DIR)/lookup_engine_fsm.sv \
	$(MAC_DIR)/mac_learn_port.sv \
	$(MAC_DIR)/mac_lookup_port.sv \
	$(MAC_DIR)/mac_addr_table_top.sv \
	$(MAC_DIR)/mac_addr_resolver.sv \
	$(MAC_DIR)/mac_forwarding_top.sv \
	$(PS_ETH_DIR)/gem_rx_w_to_axis.sv \
	$(PS_ETH_DIR)/axis_to_gem_tx_r.sv \
	$(PS_ETH_DIR)/ps_gem_axis_bridge.sv \
	$(PL_GMII_DIR)/open_eth_mac_1g_switch.sv \
	$(PL_GMII_DIR)/mac_rxd_to_switch_ingress.sv \
	$(PL_GMII_DIR)/switch_egress_to_mac_txd.sv \
	$(PL_GMII_DIR)/pl_gmii_mac_top.sv \
	$(SFP_PCS_DIR)/sfp_pcs_pkg.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_tx.sv \
	$(SFP_PCS_DIR)/sync_1000base_x.sv \
	$(SFP_PCS_DIR)/gmii_1000base_x_rx.sv \
	$(SFP_PCS_DIR)/sfp_1000base_x_pcs.sv \
	$(SFP_PCS_DIR)/sfp_port_top.sv \
	../rtl/switch_top.sv

SWITCH_TOP_TB := $(TB_DIR)/axi_mem_bfm.sv $(TB_DIR)/tb_switch_top.sv

GTH_SIM_SRCS := $(SFP_PCS_DIR)/gth_sfp_sim_model.sv
GTH_SIM_TB   := $(TB_DIR)/tb_gth_sfp_sim_model.sv

VIVADO_SETTINGS := /tools/Xilinx/2026.1/Vivado/settings64.sh

.PHONY: sim lint xsim sim-mac lint-mac xsim-mac sim-bufmgr lint-bufmgr xsim-bufmgr sim-ingress lint-ingress xsim-ingress sim-ps-eth lint-ps-eth xsim-ps-eth sim-egress lint-egress xsim-egress sim-integ lint-integ xsim-integ sim-sfp-pcs lint-sfp-pcs xsim-sfp-pcs sim-async-fifo lint-async-fifo xsim-async-fifo sim-pl-gmii lint-pl-gmii sim-sfp-port lint-sfp-port sim-cpu-port lint-cpu-port sim-mac-fwd lint-mac-fwd sim-switch-top lint-switch-top sim-gth-sim lint-gth-sim xsim-gth-sim clean

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

clean:
	rm -f tb_mac_addr_table.vvp tb_buf_mgr_core.vvp tb_ingress_top.vvp tb_ps_gem_axis_bridge.vvp tb_egress_top.vvp tb_egress_gem_tx_integration.vvp tb_sfp_1000base_x_pcs.vvp tb_async_fifo.vvp tb_pl_gmii_adapters.vvp tb_sfp_port_top.vvp tb_cpu_port_top.vvp tb_mac_forwarding_top.vvp tb_switch_top.vvp tb_gth_sfp_sim_model.vvp
	rm -rf xsim_run xsim_run_mac xsim_run_bufmgr xsim_run_ingress xsim_run_ps_eth xsim_run_egress xsim_run_integ xsim_run_sfp_pcs xsim_run_async_fifo xsim_run_pl_gmii xsim_run_sfp_port xsim_run_cpu_port xsim_run_mac_fwd xsim_run_switch_top xsim_run_gth_sim
