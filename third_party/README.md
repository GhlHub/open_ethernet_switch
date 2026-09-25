# Third-party dependencies

| Dependency | Upstream | Tracking branch |
| --- | --- | --- |
| FreeRTOS-LTS | https://github.com/FreeRTOS/FreeRTOS-LTS.git | `202604-LTS` |

FreeRTOS-LTS is a Git submodule. The parent repository records an exact commit;
the branch setting selects `202604-LTS` when explicitly updating from upstream.
The upstream branch corresponding to 202604 is named `202604-LTS`.

Initialize the recorded version and its nested dependencies after cloning:

```bash
git submodule update --init --recursive -- third_party/FreeRTOS-LTS
```

Dependency licenses and notices remain in the upstream checkout. Adding this
reference does not configure a KR260 FreeRTOS application or BSP.

The standalone R5 application also uses these vendored source subsets:

| Directory | Purpose | Provenance and local changes |
| --- | --- | --- |
| `libpayload_usb/` | USB host, hubs, xHCI and mass storage | [Pinned coreboot revision and BSD-3-Clause notices](libpayload_usb/README.md) |
| `fatfs/` | FAT filesystem access to microSD | [FatFs R0.15 and local configuration](fatfs/README.md) |
| `sha256/` | Credential verifier hashing | [Public-domain implementation and attribution](sha256/README.md) |

These are source imports, not additional Git submodules. Their upstream
notices are retained in the files; the R5 adaptation lives in
`software/r5/usb_port/` and the application sources.
