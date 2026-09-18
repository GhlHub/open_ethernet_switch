# Source provenance and reference material

[`rtl/pl_gmii/open_eth_mac_1g_switch.sv`](../rtl/pl_gmii/open_eth_mac_1g_switch.sv)
identifies its origin as `open_eth_mac_1g` from
[GhlHub/open-ethernet-cores](https://github.com/GhlHub/open-ethernet-cores).
Its existing `GPL-3.0-or-later` SPDX identifier and modification notice are
preserved. The notice describes the module rename and permanently enabled
destination acceptance for switch operation. The original import does not
record an upstream commit ID.

A copy of the GPL version 3 text is included at
[`LICENSES/GPL-3.0-or-later.txt`](../LICENSES/GPL-3.0-or-later.txt).
This inventory does not assign a new license to the other source files.

The GEM adapters refer to the AMD
[Zynq UltraScale+ technical reference manual (UG1085)](https://docs.amd.com/r/en-US/ug1085-zynq-ultrascale-trm).
The local downloaded PDF is reference material and is not included in the
source commit. Board documentation is available in the
[KR260 user guide (UG1092)](https://docs.amd.com/r/en-US/ug1092-kr260-starter-kit).

The SFP transceiver wrapper depends on AMD Transceiver Wizard IP. Its
[`gth_sfp_ip.xci`](../rtl/sfp_pcs/ip/gth_sfp_ip.xci) configuration is included;
generated vendor implementation and simulation output products are not.
Regenerating them requires the appropriate Vivado installation and vendor
terms. The portable GTH loopback model is separate from that vendor IP.

The PL Ethernet clock wrapper similarly depends on AMD Clocking Wizard IP,
configured by [`pl_eth_clk_gen_ip.xci`](../rtl/pl_gmii/ip/pl_eth_clk_gen_ip.xci).
The RGMII hardware adapter uses AMD UltraScale+ I/O, delay and clock primitives.
The standalone portable models do not replace those hardware dependencies.

The local XTP743 carrier schematic package is retained as reference material
and excluded from Git, including its PDF, ZIP and vendor readme. The readme
identifies the material as proprietary and does not itself grant redistribution
rights. [Board integration notes](board-integration.md) record the exact
schematic revision/hash, source download, and the facts used by this design.
