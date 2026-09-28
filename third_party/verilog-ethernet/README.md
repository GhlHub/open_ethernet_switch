# verilog-ethernet subset

Unmodified MIT-licensed MAC/PCS and AXI FIFO sources from
https://github.com/alexforencich/verilog-ethernet at commit
`77320a9471d19c7dd383914bc049e02d9f4f1ffb`.

`provenance.json` records the SHA-256 of every imported file, including the
license and Vivado FIFO/status timing constraint scripts. Local wrappers and
fault reconciliation are in `rtl/sfp_10g`; no upstream RTL is edited.

The upstream repository is deprecated in favor of Taxi. This project uses a
pinned MIT subset rather than tracking that migration; upstream inclusion is
not a claim of board validation. See `docs/sfp-10g.md` for integration limits.

Preserve COPYING and individual source notices when redistributing this subset.
