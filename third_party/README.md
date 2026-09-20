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
