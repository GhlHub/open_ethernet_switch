"""Extract measured interfaces from the user-supplied Xilinx A02 STEP assembly."""
from pathlib import Path
import hashlib
import tempfile
import cadquery as cq
from OCP.BRepAdaptor import BRepAdaptor_Curve

SOURCE = Path(__file__).resolve().parents[2] / 'docs/xtp744-kr260-carrier-card-3d-cad-model/KR260-startkit-A02.stp'
EXPECTED_SHA256 = 'e0f0c13cc73c76044cc1f1fdcb342210f86a7b1b683ed856eb87fc75d8a040e0'
OFFSET = (17.0, 10.0, 12.0)
# Indices are bound to the SHA256 above, never silently reused for another model.
PORT_SOLIDS = {
    'ethernet': list(range(53, 77)), 'power': [3209],
    'usb_a': [3638, 3639, 3640, 3641],
    'usb_a_column_1': [3640, 3641], 'usb_a_column_2': [3638, 3639],
    'displayport': [3642],
    'sfp': [1], 'usb_debug': [3553], 'microsd': [3581],
    'pmod': [4106, 4119, 4132, 4145],
    'fan_cover': [6925],
}


def bounds(s):
    b = s.BoundingBox()
    return [b.xmin, b.ymin, b.zmin, b.xmax, b.ymax, b.zmax]


def combined_bounds(solids):
    bs = [bounds(s) for s in solids]
    return [min(b[j] for b in bs) for j in range(3)] + [max(b[j] for b in bs) for j in range(3, 6)]


def load():
    digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError('Reference STEP changed; re-extract the interface mapping before rebuilding.')
    cache = Path(tempfile.gettempdir()) / f'kr260-{digest[:16]}.brep'
    if cache.exists():
        model = cq.Shape.importBrep(str(cache))
    else:
        print('Importing the 94 MB carrier STEP; this may take a few minutes.', flush=True)
        model = cq.importers.importStep(str(SOURCE)).val()
        cq.exporters.export(model, str(cache))
    raw = model.Solids()
    assert len(raw) == 6953
    pcb = raw[0]
    holes = set()
    bottom_z = []
    for edge in pcb.Edges():
        if edge.geomType() == 'CIRCLE' and abs(edge.radius() - 1.7018) < 1e-5:
            c = BRepAdaptor_Curve(edge.wrapped).Circle().Location()
            if abs(c.Z()) < 1e-5:
                holes.add((round(c.X(), 7), round(c.Y(), 7)))
            else:
                bottom_z.append(c.Z())
    assert len(holes) == 4
    feet = []
    for i, s in enumerate(raw):
        b = bounds(s)
        if (abs(b[3]-b[0]-8) < 0.02 and abs(b[4]-b[1]-8) < 0.02
                and b[2] < -7 and b[5] < -1.5):
            feet.append(i)
    assert feet == [6949, 6950, 6951, 6952]
    installed = [(i, s.translate(OFFSET)) for i, s in enumerate(raw) if i not in feet]
    ports = {name: combined_bounds([raw[i].translate(OFFSET) for i in ids])
             for name, ids in PORT_SOLIDS.items()}
    data = {
        'source': str(SOURCE.relative_to(SOURCE.parents[2])), 'sha256': digest,
        'revision': 'KR260-startkit-A02, STEP timestamp 2021-10-15',
        'source_solids': len(raw), 'checked_solids': len(installed),
        'removed_rubber_foot_solids': feet, 'translation_mm': OFFSET,
        'pcb_bounds_source_mm': bounds(pcb),
        'mount_holes_source_mm': sorted(holes), 'mount_hole_diameter_mm': 3.4036,
        'mount_holes_case_mm': [(x+OFFSET[0], y+OFFSET[1]) for x, y in sorted(holes)],
        'pcb_top_z_mm': OFFSET[2], 'pcb_bottom_z_mm': min(bottom_z)+OFFSET[2],
        'ports_case_bounds_mm': ports,
        'installed_bounds_mm': combined_bounds([s for _, s in installed]),
    }
    return installed, data
