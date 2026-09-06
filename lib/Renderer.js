.pragma library

// Shared stroke renderer — used by both the on-screen canvas and the offscreen
// export canvas, so what you see is exactly what lands in the clipboard.
//
// Strokes store GLOBAL LOGICAL coordinates. cfg maps them into the target
// canvas: first translate by (offsetX, offsetY), then multiply by scale.
//
//   on-screen: { offsetX: -screen.x, offsetY: -screen.y, scale: 1 }
//   export:    { offsetX: -sel.x,    offsetY: -sel.y,    scale: outputScale }

function drawStroke(ctx, stroke, cfg) {
    const pts = stroke.points || []
    if (pts.length === 0)
        return

    const s = cfg.scale || 1
    const ox = cfg.offsetX || 0
    const oy = cfg.offsetY || 0
    const X = p => (p.x + ox) * s
    const Y = p => (p.y + oy) * s

    ctx.save()
    ctx.strokeStyle = stroke.color
    ctx.lineWidth = Math.max(1, stroke.width * s)
    ctx.lineCap = "round"
    ctx.lineJoin = "round"

    switch (stroke.tool) {
    case "rect":
        if (pts.length >= 2) {
            const x0 = X(pts[0]), y0 = Y(pts[0])
            const x1 = X(pts[1]), y1 = Y(pts[1])
            ctx.strokeRect(Math.min(x0, x1), Math.min(y0, y1),
                           Math.abs(x1 - x0), Math.abs(y1 - y0))
        }
        break

    case "pen":
        ctx.beginPath()
        ctx.moveTo(X(pts[0]), Y(pts[0]))
        if (pts.length === 1) {
            // A single tap still deserves a dot
            ctx.lineTo(X(pts[0]) + 0.01, Y(pts[0]))
        } else {
            for (let i = 1; i < pts.length; i++)
                ctx.lineTo(X(pts[i]), Y(pts[i]))
        }
        ctx.stroke()
        break
    }

    ctx.restore()
}

function drawAll(ctx, strokes, cfg) {
    for (let i = 0; i < strokes.length; i++)
        drawStroke(ctx, strokes[i], cfg)
}

// Bounding box of a stroke in global logical coords, padded by line width.
function strokeBounds(stroke) {
    const pts = stroke.points || []
    if (pts.length === 0)
        return null

    let minX = pts[0].x, maxX = pts[0].x
    let minY = pts[0].y, maxY = pts[0].y
    for (let i = 1; i < pts.length; i++) {
        if (pts[i].x < minX) minX = pts[i].x
        if (pts[i].x > maxX) maxX = pts[i].x
        if (pts[i].y < minY) minY = pts[i].y
        if (pts[i].y > maxY) maxY = pts[i].y
    }

    const pad = (stroke.width || 1) + 2
    return {
        x: minX - pad,
        y: minY - pad,
        width: (maxX - minX) + pad * 2,
        height: (maxY - minY) + pad * 2
    }
}
