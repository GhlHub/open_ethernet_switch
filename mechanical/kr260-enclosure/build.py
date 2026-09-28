#!/usr/bin/env python3
"""Measured KR260 A02 clamshell. Run with requirements.txt; units are mm."""
from pathlib import Path
import json
from zipfile import ZipFile, ZIP_DEFLATED
import cadquery as cq
import trimesh
from reference import load, bounds
from render import render

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'output'
W, D, H = 164.0, 129.0, 50.0
WALL, FLOOR, SEAM = 3.0, 3.0, 16.0
INSERT_BORE, INSERT_DEPTH, SCREW_CLEARANCE = 4.2, 6.0, 3.4
CORNERS = [(6, 6), (W-6, 6), (6, D-6), (W-6, D-6)]
PINS = [(x+(3 if x<W/2 else -3), y+(3 if y<D/2 else -3)) for x,y in CORNERS]


def box(x,y,z,dx,dy,dz):
    return cq.Workplane('XY').box(dx,dy,dz,centered=False).translate((x,y,z))


def cyl(x,y,z,d,h):
    return cq.Workplane('XY').circle(d/2).extrude(h).translate((x,y,z))


def rounded(x,y,z,dx,dy,dz,r=3):
    return box(x,y,z,dx,dy,dz).edges('|Z').fillet(r)


def slot(x,y,z,length,width,depth):
    return cq.Workplane('XY').slot2D(length,width).extrude(depth).translate((x,y,z))


def cut_many(part, cutters):
    return part.cut(cq.Compound.makeCompound([c.val() for c in cutters]))


def access_openings(ref):
    p=ref['ports_case_bounds_mm']
    specs=[
        ('power_displayport', [p['power'][0]-2.3,D-5,8,p['displayport'][3]+1.9,D+5,p['power'][5]+2]),
        # 2.5 mm side allowance admits an 18 mm USB plug-body target, while
        # retaining approximately 2 mm webs to the neighbouring apertures.
        ('four_usb_a', [p['usb_a'][0]-2.5,D-5,8,p['usb_a'][3]+2.5,D+5,p['usb_a'][5]+2]),
        ('four_ethernet', [p['ethernet'][0]-2.2,D-5,7,p['ethernet'][3]+2.2,D+5,p['ethernet'][5]+4.5]),
        ('pmod_sfp_debug', [p['pmod'][0]-2,-8,p['sfp'][2]-1.5,p['usb_debug'][3]+2.5,4,p['sfp'][5]+3]),
        ('microsd_finger_recess', [-1,p['microsd'][1]-5.5,-5,p['microsd'][0]+6,p['microsd'][4]+5.5,19]),
    ]
    tools=[]
    for name,b in specs:
        tool=box(*b[:3], *(b[i+3]-b[i] for i in range(3)))
        # Round SD pocket corners without leaving a lip below the card.
        if name.startswith('microsd'):
            tool=tool.edges('|X').fillet(2)
        tools.append(tool)
    return specs, tools


def vents(ref):
    f=ref['ports_case_bounds_mm']['fan_cover']
    cx,cy=(f[0]+f[3])/2,(f[1]+f[4])/2
    roof=[slot(cx+dx,cy+dy,H-FLOOR-1,29,3,FLOOR+2)
          for dx in (-16.5,16.5) for dy in range(-30,31,6)]
    floor=[slot(cx+dx,cy+dy,-1,24,3,FLOOR+2)
           for dx in (-14,14) for dy in range(-24,25,6)]
    sides=[]
    for x in (-1,W-WALL-1):
        for yy in range(23,111,7):
            sides.append(cq.Workplane('YZ').center(yy,33).slot2D(18,3,90)
                         .extrude(WALL+2).translate((x,0,0)))
    return roof, floor, sides


def mount_posts(ref):
    z=ref['pcb_bottom_z_mm']
    posts=[]
    for x,y in ref['mount_holes_case_mm']:
        post=cyl(x,y,FLOOR-0.1,8.5,z-FLOOR+0.1)
        post=post.cut(cyl(x,y,z-INSERT_DEPTH,INSERT_BORE,INSERT_DEPTH+1))
        posts.append(post)
    return posts


def make_shells(ref):
    base=rounded(0,0,0,W,D,SEAM,6).cut(rounded(WALL,WALL,FLOOR,W-6,D-6,SEAM,3))
    lid=rounded(0,0,SEAM,W,D,H-SEAM,6).cut(rounded(WALL,WALL,SEAM-1,W-6,D-6,H-FLOOR-SEAM+1,3))
    for x,y in CORNERS:
        base=base.union(cyl(x,y,FLOOR,12,SEAM-FLOOR))
        lid=lid.union(cyl(x,y,SEAM,12,H-SEAM))
    for post in mount_posts(ref):
        base=base.union(post)
    specs, openings=access_openings(ref)
    roof, floor, sides=vents(ref)
    base=cut_many(base, openings+floor)
    lid=cut_many(lid, openings+roof+sides)
    for x,y in CORNERS:
        base=base.cut(cyl(x,y,SEAM-INSERT_DEPTH,INSERT_BORE,INSERT_DEPTH+1))
        lid=lid.cut(cyl(x,y,SEAM-1,SCREW_CLEARANCE,H-SEAM+2))
        lid=lid.cut(cyl(x,y,SEAM+4,6.6,H-SEAM))
    for x,y in PINS:
        base=base.union(cyl(x,y,SEAM-0.1,2.8,2.7).edges('>Z').chamfer(.35))
        lid=lid.cut(cyl(x,y,SEAM-0.1,3.4,3.2))
    # Shallow engraved roof labels; open-I/O windows stay free of lettering.
    for text,x,y,size in [('KR260',125,73,9),('NETWORK AUDITOR',125,64,3),
                          ('PWR / DP',40,120,3),('USB',78,120,3),('LAN',116,120,3),
                          ('PMOD / SFP+ / DEBUG',82,8,3)]:
        lettering=cq.Workplane('XY').text(text,size,.8,font='DejaVu Sans',halign='center',valign='center').translate((x,y,H-.6))
        lid=lid.cut(lettering)
    return base,lid,specs,openings


def make_coupon():
    return (rounded(0,0,0,30,18,8,2).cut(cyl(8,9,2,INSERT_BORE,7))
            .cut(cyl(22,9,-1,SCREW_CLEARANCE,10)))


def make_fit_frame(ref):
    holes=ref['mount_holes_case_mm']
    x0,y0=min(p[0] for p in holes)-5,min(p[1] for p in holes)-5
    x1,y1=max(p[0] for p in holes)+5,max(p[1] for p in holes)+5
    frame=rounded(x0,y0,0,x1-x0,y1-y0,FLOOR,5)
    frame=frame.cut(rounded(x0+10,y0+10,-1,x1-x0-20,y1-y0-20,FLOOR+2,3))
    for post in mount_posts(ref):
        frame=frame.union(post)
    return frame


def overlaps(a,b,tol=0):
    return all(a[i]<b[i+3]-tol and a[i+3]>b[i]+tol for i in range(3))


def collision_check(parts, installed, ref):
    """Conservative AABB exclusion, then exact BREP common on ALL candidates.

    Shell material lies in boundary slabs, corner cylinders/pins, and mounting
    posts. Ignoring openings makes this broad phase conservative. No components
    are skipped by size or volume; only the four removed feet are omitted.
    """
    z=ref['pcb_bottom_z_mm']
    common_regions=[(0,0,0,W,D,FLOOR),(0,0,0,WALL,D,H),(W-WALL,0,0,W,D,H),
                    (0,0,0,W,WALL,H),(0,D-WALL,0,W,D,H),(0,0,H-FLOOR,W,D,H)]
    common_regions += [(x-6,y-6,0,x+6,y+6,H) for x,y in CORNERS]
    common_regions += [(x-4.25,y-4.25,FLOOR,x+4.25,y+4.25,z) for x,y in ref['mount_holes_case_mm']]
    results={}
    for name, part in parts.items():
        tested=0; worst=0.; hits=[]
        pb=bounds(part.val())
        for i,s in installed:
            sb=bounds(s)
            if not overlaps(pb,sb) or not any(overlaps(sb,r) for r in common_regions):
                continue
            tested+=1
            v=part.val().intersect(s).Volume()
            worst=max(worst,v)
            if v>1e-5:
                hits.append({'solid':i,'volume_mm3':v})
        results[name]={'total_reference_solids':len(installed),'exact_boolean_candidates':tested,
                       'max_intersection_mm3':worst,'collisions':hits}
        print(f'{name}: {tested} detailed intersections, {len(hits)} collisions',flush=True)
    return results


def validate(base,lid,frame,coupon,installed,ref,openings):
    report={'revision':2,'outside_mm':[W,D,H], 'reference':ref,
            'fan_to_inner_roof_mm': H-FLOOR-ref['ports_case_bounds_mm']['fan_cover'][5],
            'parts':{}}
    for name,part in [('base',base),('lid',lid),('fit_frame',frame),('fit_coupon',coupon)]:
        assert part.val().isValid(),name
        assert len(part.solids().vals())==1,name
        report['parts'][name]={'valid_brep':True,'solids':1,'volume_mm3':part.val().Volume()}
    overlap=base.intersect(lid).val().Volume()
    assert overlap<1e-5,overlap
    report['shell_overlap_mm3']=overlap
    for tool in openings:
        for part in (base,lid):
            assert part.intersect(tool).val().Volume()<1e-5
    report['access_windows_unobstructed']=True
    report['board_collisions']=collision_check({'base':base,'lid':lid},installed,ref)
    (OUT/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
    assert all(not c['collisions'] for c in report['board_collisions'].values()), 'Reference collision; see validation.json'
    return report


def main():
    OUT.mkdir(exist_ok=True)
    print('Loading measured carrier reference...',flush=True)
    installed,ref=load()
    (OUT/'reference_measurements.json').write_text(json.dumps(ref,indent=2)+'\n')
    print('Building clamshell...',flush=True)
    base,lid,specs,openings=make_shells(ref)
    frame,coupon=make_fit_frame(ref),make_coupon()
    report=validate(base,lid,frame,coupon,installed,ref,openings)
    report['access_openings_case_mm']=dict(specs)
    webs=[specs[i+1][1][0]-specs[i][1][3] for i in (0,1)]
    assert min(webs)>=2, webs
    report['front_window_webs_mm']=webs
    usb_opening=dict(specs)['four_usb_a']
    usb_margins=[]
    for column in ('usb_a_column_1','usb_a_column_2'):
        b=ref['ports_case_bounds_mm'][column]
        cx=(b[0]+b[3])/2
        usb_margins.append(min(cx-9-usb_opening[0],usb_opening[3]-cx-9))
    assert min(usb_margins)>=.2, usb_margins
    report['usb_plug_body_width_target_mm']=18
    report['usb_plug_horizontal_margin_mm']=usb_margins
    print_parts={'base':base,'lid':lid.rotate((0,0,0),(1,0,0),180).translate((0,D,H)),
                 'fit_frame':frame,'fit_coupon':coupon}
    for name,part in print_parts.items():
        path=OUT/f'{name}.stl'
        cq.exporters.export(part,str(path),tolerance=.05,angularTolerance=.1)
        mesh=trimesh.load_mesh(path)
        assert mesh.is_watertight and mesh.is_winding_consistent and mesh.volume>0,name
        assert len(mesh.split())==1,name
        assert abs(mesh.bounds[0,2])<1e-5,name
        report.setdefault('stl_checks',{})[name]={'watertight':True,'consistent_winding':True,
            'connected_components':1,'on_print_bed':True,'triangles':len(mesh.faces)}
    cq.exporters.export(cq.Compound.makeCompound([base.val(),lid.val()]),str(OUT/'clamshell.step'))
    report['physical_fit_tested']=False
    (OUT/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Rendering enclosure with the carrier...',flush=True)
    render(base,lid,installed,ref,OUT/'preview.png')
    with ZipFile(ROOT/'kr260-enclosure.zip','w',ZIP_DEFLATED) as z:
        for p in [ROOT/'README.md',ROOT/'build.py',ROOT/'reference.py',ROOT/'render.py',ROOT/'requirements.txt',*sorted(p for p in OUT.iterdir() if p.is_file() and not p.name.startswith('.'))]:
            z.write(p,p.relative_to(ROOT))
    print('Finished: meshes, STEP, carrier overlay preview, validation and ZIP.',flush=True)


if __name__=='__main__':
    main()
