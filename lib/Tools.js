.pragma library

// Tool registry: toolbar order, icon, shortcut, interaction kind and size
// presets. Everything else asks this file instead of hard-coding tool ids.
//
// kind:
//   select  pick an existing stroke; drag moves it, Delete removes it
//   drag    two points, press and release: rect, ellipse, line, arrow, mosaic
//   path    every point along the drag: pen, highlighter
//   click   one point: number
//   text    one point, then a TextEdit takes over
//
// widths are the S/M/L/XL presets. Their meaning depends on the tool: line
// width, font size, mosaic block size or marker radius.

var PRESETS = ["S", "M", "L", "XL"]

var TOOLS = [
    { id: "select",      icon: "near_me",                label: "Select",      key: "S", kind: "select", widths: null },
    { id: "rect",        icon: "crop_square",            label: "Rectangle",   key: "R", kind: "drag",   widths: [2, 3, 5, 8] },
    { id: "ellipse",     icon: "radio_button_unchecked", label: "Ellipse",     key: "E", kind: "drag",   widths: [2, 3, 5, 8] },
    { id: "line",        icon: "horizontal_rule",        label: "Line",        key: "L", kind: "drag",   widths: [2, 3, 5, 8] },
    { id: "arrow",       icon: "trending_flat",          label: "Arrow",       key: "A", kind: "drag",   widths: [2, 3, 5, 8] },
    { id: "pen",         icon: "edit",                   label: "Pen",         key: "P", kind: "path",   widths: [2, 3, 5, 8] },
    { id: "highlighter", icon: "border_color",           label: "Highlighter", key: "H", kind: "path",   widths: [10, 16, 24, 32] },
    { id: "text",        icon: "text_fields",            label: "Text",        key: "T", kind: "text",   widths: [16, 24, 32, 48] },
    { id: "mosaic",      icon: "blur_on",                label: "Mosaic",      key: "M", kind: "drag",   widths: [6, 12, 18, 28] },
    { id: "number",      icon: "looks_one",              label: "Number",      key: "N", kind: "click",  widths: [10, 14, 18, 24] }
]

function byId(id) {
    for (var i = 0; i < TOOLS.length; i++)
        if (TOOLS[i].id === id)
            return TOOLS[i]
    return null
}

// letter is "A".."Z"; enabledIds restricts the match when given.
function byKey(letter, enabledIds) {
    for (var i = 0; i < TOOLS.length; i++) {
        var t = TOOLS[i]
        if (t.key === letter && (!enabledIds || enabledIds.indexOf(t.id) !== -1))
            return t
    }
    return null
}

// Tools in toolbar order, restricted to enabledIds when given.
function enabled(enabledIds) {
    if (!enabledIds)
        return TOOLS.slice()
    return TOOLS.filter(function (t) { return enabledIds.indexOf(t.id) !== -1 })
}

function kindOf(id) {
    var t = byId(id)
    return t ? t.kind : ""
}

function widthFor(id, preset) {
    var t = byId(id)
    if (!t || !t.widths)
        return 3
    var i = PRESETS.indexOf(preset)
    return t.widths[i === -1 ? 1 : i]
}

// { toolId: px } for every sizable tool at the given preset.
function defaultWidths(preset) {
    var m = {}
    for (var i = 0; i < TOOLS.length; i++)
        if (TOOLS[i].widths)
            m[TOOLS[i].id] = widthFor(TOOLS[i].id, preset)
    return m
}
