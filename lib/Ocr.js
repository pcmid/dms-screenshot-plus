.pragma library

// Text recognition with oar-ocr, which runs PaddleOCR's PP-OCRv6 models:
// its command line, reading what it prints, and the model behind selecting
// recognized text in place.
//
// `oar ocr --format json` prints one object per picture, with the regions it
// found in reading order: { text_regions: [{ text, confidence, bounding_box:
// { points: [{ x, y }, ...] } }, ...] }, in the picture's pixels. A region
// below MIN_CONFIDENCE is dropped: oar reports stray marks that way.
//
// The selection functions take lines as made by layout(): { chars, x, y, w,
// h, xs } with the characters as code points, the box in global logical
// coordinates and the x of each of the chars.length + 1 caret positions.
// A position is { line, pos }, pos being a caret index into chars.

var MIN_CONFIDENCE = 0.5

// The oar command line, the picture still to be appended: `path` with a
// leading ~ standing for `home`, then `args` split at spaces.
function oarCommand(path, args, home) {
    var p = String(path || "").trim()
    if (p === "~" || p.indexOf("~/") === 0)
        p = home + p.slice(1)
    var extra = String(args || "").trim().split(/\s+/).filter(function (a) { return a !== "" })
    return [p, "ocr"].concat(extra, ["--format", "json"])
}

// oar's output as { lines: [{ text, x0, y0, x1, y1 }] } in the picture's
// pixels, or { error: true } when it is not what oar prints.
function parse(stdout) {
    var data
    try {
        data = JSON.parse(String(stdout || ""))
    } catch (e) {
        return { error: true }
    }
    var page = Array.isArray(data) ? data[0] : data
    if (!page || !Array.isArray(page.text_regions))
        return { error: true }
    var lines = []
    for (var i = 0; i < page.text_regions.length; i++) {
        var r = page.text_regions[i]
        var text = r && typeof r.text === "string" ? r.text.trim() : ""
        var pts = r && r.bounding_box ? r.bounding_box.points : null
        if (text === "" || !Array.isArray(pts) || pts.length === 0 || r.confidence < MIN_CONFIDENCE)
            continue
        var xs = pts.map(function (p) { return p.x })
        var ys = pts.map(function (p) { return p.y })
        lines.push({ text: text, x0: Math.min.apply(null, xs), y0: Math.min.apply(null, ys),
                     x1: Math.max.apply(null, xs), y1: Math.max.apply(null, ys) })
    }
    return { lines: lines }
}

// Selection lines from parsed ones. `map` places the picture: { x, y } is its
// origin in global logical coordinates, { sx, sy } its pixels per logical
// unit. OCR gives no positions within a line, so the carets are spread over
// the box in proportion to advance(ch), each character's width in some font.
function layout(parsed, map, advance) {
    var out = []
    for (var i = 0; i < parsed.length; i++) {
        var p = parsed[i]
        // Array.from(string) splits surrogate pairs in this engine.
        var chars = p.text.match(/[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]/g)
        var x = map.x + p.x0 / map.sx
        var w = (p.x1 - p.x0) / map.sx
        var widths = chars.map(function (ch) { return Math.max(0, advance(ch)) })
        var total = widths.reduce(function (sum, v) { return sum + v }, 0)
        var xs = [x], acc = 0
        for (var j = 0; j < chars.length; j++) {
            acc += total > 0 ? widths[j] : 1
            xs.push(x + w * acc / (total > 0 ? total : chars.length))
        }
        out.push({ chars: chars, x: x, y: map.y + p.y0 / map.sy, w: w, h: (p.y1 - p.y0) / map.sy, xs: xs })
    }
    return out
}

// ── Selection ────────────────────────────────────────────────────────────────

function comparePos(a, b) {
    return a.line !== b.line ? a.line - b.line : a.pos - b.pos
}

function _ordered(a, b) {
    return comparePos(a, b) <= 0 ? [a, b] : [b, a]
}

function _distance(l, x, y) {
    var dx = x < l.x ? l.x - x : Math.max(0, x - (l.x + l.w))
    var dy = y < l.y ? l.y - y : Math.max(0, y - (l.y + l.h))
    return Math.sqrt(dx * dx + dy * dy)
}

// Index of the line nearest to (x, y) within `slack` (Infinity: the nearest
// at all, for dragging past the text), or -1.
function lineAt(lines, x, y, slack) {
    var best = -1, bestDist = Infinity
    for (var i = 0; i < lines.length; i++) {
        var d = _distance(lines[i], x, y)
        if (d <= slack && d < bestDist) {
            best = i
            bestDist = d
        }
    }
    return best
}

// The caret position in line l nearest to x.
function caretIn(l, x) {
    var best = 0
    for (var i = 1; i < l.xs.length; i++) {
        if (Math.abs(l.xs[i] - x) < Math.abs(l.xs[best] - x))
            best = i
    }
    return best
}

// The character of line l under x, clamped to the line.
function charIn(l, x) {
    for (var i = 0; i < l.chars.length - 1; i++) {
        if (x < l.xs[i + 1])
            return i
    }
    return l.chars.length - 1
}

// 2: CJK (kana, hangul, ideographs), 1: letters, digits and "_", 0: the
// rest, punctuation and spaces among it.
function charClass(ch) {
    var c = ch.codePointAt(0)
    if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x4e00 && c <= 0x9fff)
            || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0x20000 && c <= 0x323af)
            || c === 0x3005 || c === 0x3007)
        return 2
    if ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c === 0x5f
            || (c >= 0xc0 && c <= 0x24f && c !== 0xd7 && c !== 0xf7) || (c >= 0x370 && c <= 0x52f)
            || (c >= 0x1e00 && c <= 0x1eff) || (c >= 0xff10 && c <= 0xff19)
            || (c >= 0xff21 && c <= 0xff3a) || (c >= 0xff41 && c <= 0xff5a))
        return 1
    return 0
}

// [start, end) caret positions of the word around character i: a run of
// letters and digits, or of CJK characters, which has no word breaks we
// could find here, so it runs up to punctuation. A lone character otherwise.
function wordAt(chars, i) {
    var k = charClass(chars[i])
    var start = i, end = i + 1
    if (k !== 0) {
        while (start > 0 && charClass(chars[start - 1]) === k)
            start--
        while (end < chars.length && charClass(chars[end]) === k)
            end++
    }
    return [start, end]
}

// Rectangles { x, y, w, h } covering the text between positions a and b.
function rectsBetween(lines, a, b) {
    var o = _ordered(a, b), rects = []
    for (var i = o[0].line; i <= o[1].line; i++) {
        var l = lines[i]
        var s = i === o[0].line ? o[0].pos : 0
        var e = i === o[1].line ? o[1].pos : l.chars.length
        if (e > s)
            rects.push({ x: l.xs[s], y: l.y, w: l.xs[e] - l.xs[s], h: l.h })
    }
    return rects
}

// The text between positions a and b, with a line break between lines.
function textBetween(lines, a, b) {
    var o = _ordered(a, b), parts = []
    for (var i = o[0].line; i <= o[1].line; i++) {
        var chars = lines[i].chars
        parts.push(chars.slice(i === o[0].line ? o[0].pos : 0,
                               i === o[1].line ? o[1].pos : chars.length).join(""))
    }
    return parts.join("\n")
}
