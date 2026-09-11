.pragma library

// Pure geometry over strokes: bounding boxes, hit-testing and translation.
// Everything is in global logical coordinates, like the strokes themselves.
// Nothing here mutates a stroke — translate() returns a new object, which is
// what keeps the snapshot undo history honest.

// Normalised rectangle of a two-point stroke.
function rectOf(stroke) {
    var p = stroke.points
    if (!p || p.length < 2)
        return { x: p && p[0] ? p[0].x : 0, y: p && p[0] ? p[0].y : 0, w: 0, h: 0 }
    var x0 = Math.min(p[0].x, p[1].x), y0 = Math.min(p[0].y, p[1].y)
    var x1 = Math.max(p[0].x, p[1].x), y1 = Math.max(p[0].y, p[1].y)
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
}

function numberRadius(stroke) {
    return Math.max(6, stroke.width)
}

// Bounding box padded by whatever the tool draws beyond its points.
function bounds(stroke) {
    var p = stroke.points || []
    if (p.length === 0)
        return null

    var pad
    switch (stroke.tool) {
    case "text":
        return { x: p[0].x - 2, y: p[0].y - 2, w: (stroke.w || 0) + 4, h: (stroke.h || 0) + 4 }
    case "number": {
        var r = numberRadius(stroke) + 2
        return { x: p[0].x - r, y: p[0].y - r, w: r * 2, h: r * 2 }
    }
    case "mosaic": {
        var m = rectOf(stroke)
        return { x: m.x, y: m.y, w: m.w, h: m.h }
    }
    case "arrow":
        pad = Math.max(15, stroke.width * 4) / 2 + stroke.width
        break
    case "highlighter":
        pad = stroke.width / 2 + 2
        break
    default:
        pad = (stroke.width || 1) / 2 + 2
    }

    var minX = p[0].x, maxX = p[0].x, minY = p[0].y, maxY = p[0].y
    for (var i = 1; i < p.length; i++) {
        if (p[i].x < minX) minX = p[i].x
        if (p[i].x > maxX) maxX = p[i].x
        if (p[i].y < minY) minY = p[i].y
        if (p[i].y > maxY) maxY = p[i].y
    }
    return { x: minX - pad, y: minY - pad, w: (maxX - minX) + pad * 2, h: (maxY - minY) + pad * 2 }
}

function inRect(r, x, y, pad) {
    pad = pad || 0
    return x >= r.x - pad && x <= r.x + r.w + pad && y >= r.y - pad && y <= r.y + r.h + pad
}

// Squared distance from (x, y) to segment a-b.
function segDist2(x, y, a, b) {
    var dx = b.x - a.x, dy = b.y - a.y
    var len2 = dx * dx + dy * dy
    var t = len2 === 0 ? 0 : ((x - a.x) * dx + (y - a.y) * dy) / len2
    t = Math.max(0, Math.min(1, t))
    var px = a.x + t * dx - x, py = a.y + t * dy - y
    return px * px + py * py
}

function nearPolyline(pts, x, y, tol) {
    if (pts.length === 1)
        return segDist2(x, y, pts[0], pts[0]) <= tol * tol
    var t2 = tol * tol
    for (var i = 1; i < pts.length; i++)
        if (segDist2(x, y, pts[i - 1], pts[i]) <= t2)
            return true
    return false
}

// Per-tool precise test. `tol` is the base tolerance in logical px.
function hit(stroke, x, y, tol) {
    var b = bounds(stroke)
    if (!b || !inRect(b, x, y, tol))
        return false

    var p = stroke.points
    var half = (stroke.width || 1) / 2

    switch (stroke.tool) {
    case "pen":
        return nearPolyline(p, x, y, tol + half)
    case "highlighter":
        return nearPolyline(p, x, y, tol + half)
    case "line":
    case "arrow":
        return p.length >= 2 && segDist2(x, y, p[0], p[p.length - 1]) <= Math.pow(tol + half, 2)
    case "rect": {
        // Only the frame counts, so strokes drawn inside a box stay reachable.
        var r = rectOf(stroke)
        var t = tol + half
        var inside = inRect(r, x, y, t)
        var deepInside = inRect(r, x, y, -t)
        return inside && !deepInside
    }
    case "ellipse": {
        var e = rectOf(stroke)
        var rx = e.w / 2, ry = e.h / 2
        if (rx < 1 || ry < 1)
            return true
        var nx = (x - (e.x + rx)) / rx, ny = (y - (e.y + ry)) / ry
        var n = nx * nx + ny * ny
        var tolN = Math.max(0.08, (tol + half) / Math.max(rx, ry))
        return Math.abs(n - 1) <= tolN
    }
    case "mosaic":
        return inRect(rectOf(stroke), x, y, 0)
    case "number": {
        var r2 = numberRadius(stroke) + tol
        var dx = x - p[0].x, dy = y - p[0].y
        return dx * dx + dy * dy <= r2 * r2
    }
    case "text":
        return inRect({ x: p[0].x, y: p[0].y, w: stroke.w || 0, h: stroke.h || 0 }, x, y, tol)
    }
    return false
}

// Topmost (latest) stroke under the point, or null.
function strokeAt(strokes, x, y, tol) {
    tol = tol === undefined ? 6 : tol
    for (var i = strokes.length - 1; i >= 0; i--)
        if (hit(strokes[i], x, y, tol))
            return strokes[i]
    return null
}

// A copy of the stroke moved by (dx, dy). The original is left untouched.
function translate(stroke, dx, dy) {
    var out = {}
    for (var k in stroke)
        out[k] = stroke[k]
    out.points = stroke.points.map(function (pt) { return { x: pt.x + dx, y: pt.y + dy } })
    return out
}

function indexOfId(strokes, id) {
    for (var i = 0; i < strokes.length; i++)
        if (strokes[i].id === id)
            return i
    return -1
}
