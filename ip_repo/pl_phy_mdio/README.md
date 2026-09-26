# PL PHY MDIO management

`ghlhub.org:ethernet:pl_phy_mdio:1.0` packages one independent PHY-management
bus. The public top is `switch_pl_phy_mdio`; `manifest.json` owns its source
closure. It includes the real IOBUF, Clause 22 master, register shim and
DP83867 startup/link-polling sequencer.

Connect `s_axi`, `clk` and `rst_n` to the same control domain. Connect
`phy_reset_released_i` to the board's PHY-reset-release request; the IP owns
the two-stage crossing into `clk`. Keep `mdio_io` bidirectional through the
board top and route `mdc_o` to its PHY. Board pin assignments and external
MDIO timing budgets belong to the board constraint set. The package does
not generate RGMII clocks or drive the PHY reset pin.

KR260 uses one instance per PL port, at PHY addresses 2 and 3. Default
startup and polling counts assume the existing 142.857 MHz control clock;
review these parameters and the software-programmed MDC divider when
reusing the block at another frequency. The initializer specifically
configures the DP83867; it is not a generic PHY initialization sequence.

See the [interface contract](../INTERFACES.md#pl-phy-management-pl_phy_mdio-10)
and [MDIO register map](../../docs/board-integration.md#mdio-management-interface).

Run the actual public-wrapper tests with:

```sh
python3 scripts/check_ip_tests.py --core pl_phy_mdio
python3 scripts/check_ip_tests.py --core pl_phy_mdio --catalog build/ip_catalog
```

Only the pad primitive is modeled for simulation. The controller and
sequencer under test are the same source files packaged for synthesis.
