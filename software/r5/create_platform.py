"""Run with vitis -s software/r5/create_platform.py after exporting hardware."""
from pathlib import Path
import shutil
import vitis
root = Path(__file__).resolve().parents[2]
client = vitis.create_client()
client.set_workspace(str(root / 'build/r5/workspace'))
if (root / 'build/r5/workspace/kr260_r5').exists():
    platform = client.get_component(name='kr260_r5')
    platform.update_hw(str(root / 'build/r5/kr260_switch.xsa'))
else:
    platform = client.create_platform_component(name='kr260_r5',
        hw_design=str(root / 'build/r5/kr260_switch.xsa'),
        cpu='psu_cortexr5_0', os='standalone', domain_name='r5_bsp')
# The FSBL also drains STDOUT through the UART driver before handoff.
# Leaving its default console at CoreSight makes that drain wait forever.
for name in ('r5_bsp', 'zynqmp_fsbl'):
    domain = platform.get_domain(name=name)
    domain.set_config('os', 'standalone_stdout', 'psu_uart_1')
    domain.set_config('os', 'standalone_stdin', 'psu_uart_1')
# update_hw refreshes the SDT, but Vitis can retain the FSBL's old local
# psu_init sources. Keep the boot application's initialization matched to XSA.
platform_dir = root / 'build/r5/workspace/kr260_r5'
for name in ('psu_init.c', 'psu_init.h'):
    destination = platform_dir / 'zynqmp_fsbl' / name
    if destination.exists():
        shutil.copy2(platform_dir / 'hw/sdt' / name, destination)
platform.build()
# A new platform may create its boot application only during the first build.
# Also catch any build step that replaces our refreshed source with an old copy.
if ((platform_dir / 'zynqmp_fsbl/psu_init.c').read_bytes() !=
        (platform_dir / 'hw/sdt/psu_init.c').read_bytes()):
    for name in ('psu_init.c', 'psu_init.h'):
        shutil.copy2(platform_dir / 'hw/sdt' / name,
                     platform_dir / 'zynqmp_fsbl' / name)
    platform.build()
vitis.dispose()
