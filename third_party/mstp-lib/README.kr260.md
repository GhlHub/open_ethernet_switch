# mstp-lib dependency

Upstream: https://github.com/adigostin/mstp-lib
Pinned commit: 40ce5ccc511dcd773cbe940f6cecb1e1e463f5f7
License: Apache-2.0 (see LICENSE and source headers).

Vendored library directory only; upstream files are unmodified. The KR260 uses
one common spanning tree, selectable classic STP (version 0) or RSTP (version 2).
MSTP/VLAN instances are not exposed. Logging is compiled out (STP_USE_LOG=0).
C++03 code is built without exceptions or RTTI and called through its C API.
Platform adapter: software/r5/src/stp.c; task/hardware glue: stp_task.c.
