"""Depth-buffered review views of the shells and supplied carrier geometry."""
import vtk
from reference import bounds


def mapper_for(shape):
    vertices,triangles=shape.tessellate(.25)
    points=vtk.vtkPoints()
    for v in vertices:
        points.InsertNextPoint(*v.toTuple())
    cells=vtk.vtkCellArray()
    for t in triangles:
        cells.InsertNextCell(3,t)
    poly=vtk.vtkPolyData();poly.SetPoints(points);poly.SetPolys(cells)
    normals=vtk.vtkPolyDataNormals();normals.SetInputData(poly);normals.SetFeatureAngle(35)
    mapper=vtk.vtkPolyDataMapper();mapper.SetInputConnection(normals.GetOutputPort())
    return mapper


def render(base,lid,installed,ref,path):
    parts=[(mapper_for(base.val()),(.23,.32,.39),'base'),
           (mapper_for(lid.val()),(.70,.78,.84),'lid')]
    for i,s in installed:
        b=bounds(s)
        # Preview omits tiny components only. Collision checks include them all.
        if (b[3]-b[0])*(b[4]-b[1])*(b[5]-b[2])<10:
            continue
        color=(.13,.40,.23) if i in (0,4158) else ((.12,.13,.15) if i>=6914 or i==53 else (.68,.71,.74))
        parts.append((mapper_for(s),color,'board'))
    window=vtk.vtkRenderWindow();window.SetOffScreenRendering(1);window.SetSize(2200,1700);window.SetMultiSamples(4)
    views=[('FRONT / POWER, DISPLAYPORT, USB, FOUR LAN',(-250,350,220),(82,68,23),115,False),
           ('REAR / PMOD, SFP+, USB DEBUG',(300,-320,210),(82,65,23),115,False),
           ('EXPLODED / FIXED BOARD MOUNTS',(-260,330,270),(82,65,52),140,True),
           ('MICROSD / FINGER RECESS',(-150,68,-50),(12,68,10),31,False)]
    for n,(title,pos,target,scale,exploded) in enumerate(views):
        r=vtk.vtkRenderer();r.SetViewport((n%2)/2,1-(n//2+1)/2,(n%2+1)/2,1-(n//2)/2);r.SetBackground(.95,.96,.97);window.AddRenderer(r)
        for mapper,color,kind in parts:
            a=vtk.vtkActor();a.SetMapper(mapper);a.GetProperty().SetColor(*color)
            a.GetProperty().SetAmbient(.25);a.GetProperty().SetDiffuse(.75)
            if exploded and kind=='lid':a.SetPosition(0,0,42)
            r.AddActor(a)
        c=r.GetActiveCamera();c.SetPosition(*pos);c.SetFocalPoint(*target);c.SetViewUp(0,0,1);c.ParallelProjectionOn();c.SetParallelScale(scale);r.ResetCameraClippingRange()
        for text,y,size in [(title,.93,23),('KR260 A02  |  164 x 129 x 50 mm  |  Four M3 shell screws',.045,20)]:
            t=vtk.vtkTextActor();t.SetInput(text);t.GetTextProperty().SetFontSize(size);t.GetTextProperty().SetColor(.13,.2,.27);t.GetTextProperty().SetBackgroundColor(.95,.96,.97);t.GetTextProperty().SetBackgroundOpacity(1);t.GetTextProperty().SetJustificationToCentered();t.GetPositionCoordinate().SetCoordinateSystemToNormalizedViewport();t.GetPositionCoordinate().SetValue(.5,y);r.AddViewProp(t)
    window.Render();capture=vtk.vtkWindowToImageFilter();capture.SetInput(window);capture.Update()
    writer=vtk.vtkPNGWriter();writer.SetFileName(str(path));writer.SetInputConnection(capture.GetOutputPort());writer.Write();window.Finalize()
