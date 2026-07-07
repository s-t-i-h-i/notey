import PencilKit

func crop(drawing: PKDrawing, to bounds: CGRect) -> PKDrawing {
    var newStrokes: [PKStroke] = []
    for stroke in drawing.strokes {
        if bounds.contains(stroke.renderBounds) {
            newStrokes.append(stroke)
            continue
        }
        
        var currentPoints: [PKStrokePoint] = []
        for point in stroke.path {
            let loc = point.location.applying(stroke.transform)
            if bounds.contains(loc) {
                currentPoints.append(point)
            } else {
                if currentPoints.count > 1 {
                    let newPath = PKStrokePath(controlPoints: currentPoints, creationDate: stroke.path.creationDate)
                    let newStroke = PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
                    newStrokes.append(newStroke)
                }
                currentPoints = []
            }
        }
        if currentPoints.count > 1 {
            let newPath = PKStrokePath(controlPoints: currentPoints, creationDate: stroke.path.creationDate)
            let newStroke = PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
            newStrokes.append(newStroke)
        }
    }
    return PKDrawing(strokes: newStrokes)
}
