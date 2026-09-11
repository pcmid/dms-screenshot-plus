.pragma library

.import "Hit.js" as Hit

// Draws strokes onto a Canvas 2D context at scale 1. Strokes hold GLOBAL
// LOGICAL coordinates; cfg.offsetX/offsetY translate them into the canvas.
// Export is a grabToImage() of the QML scene, so there is no separate export
// scale here — what this paints is what gets exported.
//
// cfg = {
//   offsetX, offsetY   applied before drawing
//   excludeId          stroke id to skip (being dragged / edited elsewhere)
//   numberIndex        { strokeId: displayedNumber }, see numbering()
//   fontFamily         for text and number labels
// }

var ARROW_SPREAD = Math.PI / 7          // half-angle of the head
var ARROW_BASE = Math.cos(ARROW_SPREAD) // shaft shortening so it ends on the head's base
var HIGHLIGHT_ALPHA = 0.4
var MAX_CANVAS_FONT_PX = 48             // above this Qt's glyph cache falls off a cliff

function fontFamily(cfg) {
    return cfg && cfg.fontFamily ? cfg.fontFamily : "sans-serif"
}

function fontString(px, family, bold) {
    var generic = ["sans-serif", "serif", "monospace", "cursive", "fantasy", "system-ui"]
    var fam = generic.indexOf(family) !== -1 ? family : '"' + family.replace(/"/g, '\\"') + '"'
    return (bold ? "bold " : "") + Math.round(px) + "px " + fam
}

// Numbers are displayed in creation order (by id), 1..N, regardless of where
// the stroke sits in the array — so deleting one in the middle renumbers.
function numbering(strokes) {
    var ids = []
    for (var i = 0; i < strokes.length; i++)
        if (strokes[i].tool === "number")
            ids.push(strokes[i].id)
    ids.sort(function (a, b) { return a - b })
    var map = {}
    for (var j = 0; j < ids.length; j++)
        map[ids[j]] = j + 1
    return map
}

function luminance(hex) {
    var c = String(hex).replace("#", "")
    if (c.length === 8) c = c.substr(2) // #AARRGGBB
    if (c.length !== 6) return 0
    var r = parseInt(c.substr(0, 2), 16) / 255
    var g = parseInt(c.substr(2, 2), 16) / 255
    var b = parseInt(c.substr(4, 2), 16) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrastFor(hex) {
    return luminance(hex) > 0.6 ? "#000000" : "#ffffff"
}

function drawArrowLike(ctx, X, Y, p0, p1, width, withHead) {
    var x0 = X(p0), y0 = Y(p0), x1 = X(p1), y1 = Y(p1)
    var dx = x1 - x0, dy = y1 - y0
    var len = Math.sqrt(dx * dx + dy * dy)
    if (len < 0.5)
        return
    var angle = Math.atan2(dy, dx)

    if (!withHead) {
        ctx.beginPath()
        ctx.moveTo(x0, y0)
        ctx.lineTo(x1, y1)
        ctx.stroke()
        return
    }

    var head = Math.max(15, width * 4)
    var shaft = Math.max(0, len - head * ARROW_BASE)
    ctx.beginPath()
    ctx.moveTo(x0, y0)
    ctx.lineTo(x0 + shaft * Math.cos(angle), y0 + shaft * Math.sin(angle))
    ctx.stroke()

    ctx.beginPath()
    ctx.moveTo(x1, y1)
    ctx.lineTo(x1 - head * Math.cos(angle - ARROW_SPREAD), y1 - head * Math.sin(angle - ARROW_SPREAD))
    ctx.lineTo(x1 - head * Math.cos(angle + ARROW_SPREAD), y1 - head * Math.sin(angle + ARROW_SPREAD))
    ctx.closePath()
    ctx.fill()
}

function drawStroke(ctx, stroke, cfg) {
    var pts = stroke.points || []
    if (pts.length === 0)
        return
    if (stroke.tool === "mosaic")
        return // rendered by ShaderEffectSource items, not the canvas

    var ox = (cfg && cfg.offsetX) || 0
    var oy = (cfg && cfg.offsetY) || 0
    var X = function (p) { return p.x + ox }
    var Y = function (p) { return p.y + oy }

    ctx.save()
    ctx.strokeStyle = stroke.color
    ctx.fillStyle = stroke.color
    ctx.lineWidth = Math.max(1, stroke.width)
    ctx.lineCap = "round"
    ctx.lineJoin = "round"

    switch (stroke.tool) {
    case "rect": {
        var r = Hit.rectOf(stroke)
        ctx.strokeRect(r.x + ox, r.y + oy, r.w, r.h)
        break
    }

    case "ellipse": {
        var e = Hit.rectOf(stroke)
        if (e.w > 0 && e.h > 0) {
            ctx.save()
            ctx.beginPath()
            ctx.translate(e.x + ox + e.w / 2, e.y + oy + e.h / 2)
            ctx.scale(e.w / 2, e.h / 2)
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.restore()   // before stroke(), or the pen gets scaled too
            ctx.stroke()
        }
        break
    }

    case "line":
        if (pts.length >= 2)
            drawArrowLike(ctx, X, Y, pts[0], pts[pts.length - 1], stroke.width, false)
        break

    case "arrow":
        if (pts.length >= 2)
            drawArrowLike(ctx, X, Y, pts[0], pts[pts.length - 1], stroke.width, true)
        break

    case "highlighter":
        ctx.globalAlpha = HIGHLIGHT_ALPHA
        ctx.lineCap = "square"
        ctx.lineJoin = "miter"
        // fallthrough
    case "pen":
        ctx.beginPath()
        ctx.moveTo(X(pts[0]), Y(pts[0]))
        if (pts.length === 1)
            ctx.lineTo(X(pts[0]) + 0.01, Y(pts[0])) // a tap still leaves a dot
        for (var i = 1; i < pts.length; i++)
            ctx.lineTo(X(pts[i]), Y(pts[i]))
        ctx.stroke()
        break

    case "number": {
        var radius = Hit.numberRadius(stroke)
        var cx = X(pts[0]), cy = Y(pts[0])
        ctx.beginPath()
        ctx.arc(cx, cy, radius, 0, Math.PI * 2)
        ctx.fill()

        var n = (cfg && cfg.numberIndex && cfg.numberIndex[stroke.id]) || 1
        var label = String(n)
        var wanted = radius * 1.35
        var px = Math.min(MAX_CANVAS_FONT_PX, wanted)
        var extra = wanted / px
        ctx.fillStyle = contrastFor(stroke.color)
        ctx.font = fontString(px, fontFamily(cfg), true)
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.save()
        ctx.translate(cx, cy)
        ctx.scale(extra, extra)
        // "middle" centres the em box, not the digits, which sit ~15% high.
        // Measured on the exported PNG: digit centre vs circle centre.
        ctx.fillText(label, 0, px * 0.15)
        ctx.restore()
        break
    }

    case "text": {
        var lines = String(stroke.text || "").split("\n")
        var size = stroke.width
        var lh = stroke.lineHeight || size * 1.3
        var family = stroke.font || fontFamily(cfg)
        var fpx = Math.min(MAX_CANVAS_FONT_PX, size)
        var fscale = size / fpx
        ctx.font = fontString(fpx, family, false)
        ctx.textAlign = "left"
        ctx.textBaseline = "top"
        ctx.save()
        ctx.translate(X(pts[0]), Y(pts[0]))
        ctx.scale(fscale, fscale)
        for (var li = 0; li < lines.length; li++)
            ctx.fillText(lines[li], 0, (li * lh) / fscale)
        ctx.restore()
        break
    }
    }

    ctx.restore()
}

function drawAll(ctx, strokes, cfg) {
    var c = cfg || {}
    if (!c.numberIndex)
        c = Object.assign({}, c, { numberIndex: numbering(strokes) })
    for (var i = 0; i < strokes.length; i++) {
        if (c.excludeId !== undefined && c.excludeId >= 0 && strokes[i].id === c.excludeId)
            continue
        drawStroke(ctx, strokes[i], c)
    }
}

// Dashed frame around a stroke (selection feedback). Two-tone so it reads on
// any background: solid light line underneath, dark dashes on top.
function drawSelection(ctx, stroke, cfg) {
    var b = Hit.bounds(stroke)
    if (!b)
        return
    var ox = (cfg && cfg.offsetX) || 0
    var oy = (cfg && cfg.offsetY) || 0
    var pad = 3
    var x = Math.round(b.x + ox) - pad + 0.5, y = Math.round(b.y + oy) - pad + 0.5
    var w = Math.round(b.w) + pad * 2, h = Math.round(b.h) + pad * 2
    ctx.save()
    ctx.lineWidth = 1
    ctx.strokeStyle = "rgba(255,255,255,0.9)"
    ctx.setLineDash([])
    ctx.strokeRect(x, y, w, h)
    ctx.strokeStyle = "rgba(0,0,0,0.85)"
    ctx.setLineDash([4, 4])
    ctx.strokeRect(x, y, w, h)
    ctx.restore()
}
