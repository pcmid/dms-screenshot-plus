import QtQuick
import qs.Common
import "lib/Renderer.js" as Renderer
import "lib/Hit.js" as Hit
import "lib/Tools.js" as Tools

// Everything drawn on top of the frozen frame, for one screen.
//
//   exportRoot        the subtree that becomes the exported image: a copy of
//                     the frame, the mosaics, the committed strokes and the
//                     stroke being drawn or dragged
//   selectionOutline  dashed frame around the selected stroke; a sibling of
//                     exportRoot so it is never exported
//   textEditor        the TextEdit used while typing; also a sibling
//
// Public functions take global logical coordinates.
Item {
    id: annot

    property var overlay: null      // the PanelWindow: coordinates and selection
    property var ctl: null          // the daemon: strokes, tool, color
    property var frameItem: null    // ScreencopyView or Image holding the frame

    readonly property alias exportItem: exportRoot
    readonly property bool editingText: textSession !== null
    // Hidden from bakedCanvas while it is dragged or edited.
    readonly property int hiddenId: dragId >= 0 ? dragId : (textSession ? textSession.id : -1)

    // Font for the Canvas (text tool, number labels) and for the TextEdit, so
    // what is typed is what gets painted. Canvas goes through QPainter's
    // outline rasterizer, which breaks glyphs with overlapping contours in
    // variable fonts (DMS's default Inter Variable renders a broken "4").
    readonly property string canvasFont: /variable/i.test(Theme.fontFamily) ? "sans-serif" : Theme.fontFamily

    // ── Transient state, never part of the undo history ──────────────────────

    property string activeTool: ""     // stroke being drawn
    property var activePoints: []

    property int dragId: -1            // stroke being moved with the select tool
    property var dragStroke: null
    property real dragX0: 0
    property real dragY0: 0
    property real moveDx: 0
    property real moveDy: 0

    property var textSession: null     // { x, y, id (-1 for new), fontSize }

    // Canvases repaint by tile; only the tiles under the preview are marked
    // dirty per mouse move. Repainting a whole 4K canvas dropped frames.
    readonly property size tile: Qt.size(256, 256)
    property var _lastActiveBounds: null
    property var _lastStrokes: []

    readonly property var mosaics: ctl ? ctl.strokes.filter(s => s.tool === "mosaic") : []
    readonly property var selectedStroke: {
        if (!ctl || ctl.selectedId < 0)
            return null
        const i = Hit.indexOfId(ctl.strokes, ctl.selectedId)
        return i === -1 ? null : ctl.strokes[i]
    }
    readonly property var selectedBounds: selectedStroke ? Hit.bounds(selectedStroke) : null

    anchors.fill: parent

    onHiddenIdChanged: bakedCanvas.requestPaint()

    // ── Drawing ──────────────────────────────────────────────────────────────

    // What activeCanvas shows right now, as a stroke, or null.
    function _previewStroke() {
        if (dragId >= 0 && dragStroke)
            return Hit.translate(dragStroke, moveDx, moveDy)
        if (activePoints.length > 0 && activeTool !== "mosaic")
            return { "id": ctl.nextStrokeId, "tool": activeTool, "color": String(ctl.strokeColor),
                     "width": ctl.currentWidth, "points": activePoints }
        return null
    }

    // Mark the union of the preview's previous and current bounds dirty.
    function _markActiveDirty() {
        const s = _previewStroke()
        const b = s ? Hit.bounds(s) : null
        let u = b
        if (_lastActiveBounds) {
            const o = _lastActiveBounds
            u = b ? { "x": Math.min(b.x, o.x), "y": Math.min(b.y, o.y),
                      "w": Math.max(b.x + b.w, o.x + o.w) - Math.min(b.x, o.x),
                      "h": Math.max(b.y + b.h, o.y + o.h) - Math.min(b.y, o.y) } : o
        }
        _lastActiveBounds = b
        if (!u)
            return
        const pad = 6
        activeCanvas.markDirty(Qt.rect(u.x - overlay.originX - overlay.selLX - pad,
                                       u.y - overlay.originY - overlay.selLY - pad,
                                       u.w + pad * 2, u.h + pad * 2))
    }

    function beginStroke(gx, gy) {
        activeTool = ctl.activeTool
        const p = { "x": gx, "y": gy }
        activePoints = Tools.kindOf(activeTool) === "drag" ? [p, p] : [p]
        _lastActiveBounds = null
        _markActiveDirty()
    }

    function updateStroke(gx, gy) {
        if (activePoints.length === 0)
            return
        const p = { "x": gx, "y": gy }
        const pts = activePoints.slice()
        if (Tools.kindOf(activeTool) === "drag")
            pts[1] = p
        else
            pts.push(p)
        activePoints = pts
        _markActiveDirty()
    }

    function endStroke() {
        const pts = activePoints
        const tool = activeTool
        activePoints = []
        activeTool = ""
        _lastActiveBounds = null
        activeCanvas.requestPaint()
        if (pts.length === 0)
            return
        if (Tools.kindOf(tool) === "drag") {
            const dx = pts[1].x - pts[0].x, dy = pts[1].y - pts[0].y
            if (dx * dx + dy * dy < 4)
                return   // a click, not a drag
        }
        ctl.pushStroke({ "tool": tool, "color": String(ctl.strokeColor), "width": ctl.currentWidth, "points": pts })
    }

    // ── Moving (select tool) ─────────────────────────────────────────────────

    function hitAt(gx, gy) {
        return Hit.strokeAt(ctl.strokes, gx, gy, 6)
    }

    function beginMove(stroke, gx, gy) {
        dragStroke = stroke
        dragX0 = gx
        dragY0 = gy
        moveDx = 0
        moveDy = 0
        dragId = stroke.id
        _lastActiveBounds = null
        _markActiveDirty()
    }

    function updateMove(gx, gy) {
        if (dragId < 0)
            return
        moveDx = gx - dragX0
        moveDy = gy - dragY0
        _markActiveDirty()
    }

    function endMove() {
        if (dragId < 0)
            return
        const id = dragId, s = dragStroke, dx = moveDx, dy = moveDy
        dragId = -1
        dragStroke = null
        moveDx = 0
        moveDy = 0
        _lastActiveBounds = null
        activeCanvas.requestPaint()
        if (dx !== 0 || dy !== 0)
            ctl.replaceStroke(id, Hit.translate(s, dx, dy))
    }

    // ── Text ─────────────────────────────────────────────────────────────────

    function beginTextEdit(gx, gy, existing) {
        if (textSession)
            commitTextEdit()
        textSession = {
            "x": existing ? existing.points[0].x : gx,
            "y": existing ? existing.points[0].y : gy,
            "id": existing ? existing.id : -1,
            "fontSize": existing ? existing.width : ctl.currentWidth
        }
        textEdit.text = existing ? existing.text : ""
        if (existing)
            ctl.strokeColor = existing.color
        textEdit.cursorPosition = textEdit.length
        textEdit.forceActiveFocus()
    }

    function commitTextEdit() {
        const s = textSession
        if (!s)
            return
        const text = textEdit.text
        const stroke = {
            "tool": "text",
            "color": String(ctl.strokeColor),
            "width": s.fontSize,
            "points": [{ "x": s.x, "y": s.y }],
            "text": text,
            "w": Math.ceil(textEdit.contentWidth),
            "h": Math.ceil(textEdit.contentHeight),
            "lineHeight": textEdit.contentHeight / Math.max(1, textEdit.lineCount),
            "font": textEdit.font.family
        }
        _endTextSession()
        if (text.trim() === "") {
            if (s.id >= 0)
                ctl.deleteStroke(s.id)
        } else if (s.id >= 0) {
            ctl.replaceStroke(s.id, stroke)
        } else {
            ctl.pushStroke(stroke)
        }
    }

    function cancelTextEdit() {
        if (textSession)
            _endTextSession()
    }

    function _endTextSession() {
        textSession = null
        textEdit.text = ""
        if (overlay && overlay.keyHandler)
            overlay.keyHandler.forceActiveFocus()
    }

    // ── exportRoot ───────────────────────────────────────────────────────────

    Item {
        id: exportRoot

        x: overlay.selLX
        y: overlay.selLY
        width: overlay.selLW
        height: overlay.selLH
        clip: true
        visible: overlay.hasSel && overlay.frameReady

        // Frame copy, reusing the texture the frame item already holds.
        // textureSize pins it to source pixels so the grab samples at full
        // resolution rather than at the on-screen size.
        ShaderEffectSource {
            anchors.fill: parent
            sourceItem: annot.frameItem
            sourceRect: Qt.rect(overlay.selLX, overlay.selLY, overlay.selLW, overlay.selLH)
            textureSize: Qt.size(Math.max(1, Math.round(overlay.selLW * overlay.outScale)),
                                 Math.max(1, Math.round(overlay.selLH * overlay.outScale)))
            live: true
            recursive: false
        }

        // Mosaic: the frame region rendered at (size / block) pixels, then
        // scaled up without smoothing. Works with either backend.
        Repeater {
            model: annot.mosaics
            delegate: ShaderEffectSource {
                required property var modelData
                readonly property var r: Hit.rectOf(modelData)
                readonly property real block: Math.max(2, modelData.width)
                x: r.x - overlay.originX - overlay.selLX
                y: r.y - overlay.originY - overlay.selLY
                width: r.w
                height: r.h
                sourceItem: annot.frameItem
                sourceRect: Qt.rect(r.x - overlay.originX, r.y - overlay.originY, r.w, r.h)
                textureSize: Qt.size(Math.max(1, Math.ceil(r.w / block)), Math.max(1, Math.ceil(r.h / block)))
                smooth: false
                mipmap: false
                live: true
                recursive: false
            }
        }

        // Preview while dragging out a mosaic.
        ShaderEffectSource {
            readonly property bool on: annot.activeTool === "mosaic" && annot.activePoints.length >= 2
            readonly property var r: on ? Hit.rectOf({ "points": annot.activePoints }) : ({ "x": 0, "y": 0, "w": 0, "h": 0 })
            readonly property real block: Math.max(2, ctl ? ctl.currentWidth : 8)
            visible: on && r.w >= 1 && r.h >= 1
            x: r.x - overlay.originX - overlay.selLX
            y: r.y - overlay.originY - overlay.selLY
            width: Math.max(1, r.w)
            height: Math.max(1, r.h)
            sourceItem: visible ? annot.frameItem : null
            sourceRect: Qt.rect(r.x - overlay.originX, r.y - overlay.originY, Math.max(1, r.w), Math.max(1, r.h))
            textureSize: Qt.size(Math.max(1, Math.ceil(r.w / block)), Math.max(1, Math.ceil(r.h / block)))
            smooth: false
            mipmap: false
            live: true
            recursive: false
        }

        // Committed strokes. Screen-sized but positioned relative to the clip
        // item, so stroke coordinates do not depend on the selection.
        Canvas {
            id: bakedCanvas
            x: -overlay.selLX
            y: -overlay.selLY
            width: overlay.width
            height: overlay.height
            renderStrategy: Canvas.Cooperative
            tileSize: annot.tile

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (!ctl)
                    return
                Renderer.drawAll(ctx, ctl.strokes, {
                    "offsetX": -overlay.originX, "offsetY": -overlay.originY,
                    "excludeId": annot.hiddenId, "fontFamily": annot.canvasFont
                })
            }

            Connections {
                target: ctl
                function onStrokesChanged() {
                    // Appending one stroke only dirties its own tiles; undo,
                    // delete and move repaint everything.
                    const prev = annot._lastStrokes, next = ctl.strokes
                    annot._lastStrokes = next
                    let appended = next.length === prev.length + 1
                    for (let i = 0; appended && i < prev.length; i++)
                        appended = next[i] === prev[i]
                    const b = appended ? Hit.bounds(next[next.length - 1]) : null
                    if (!b) {
                        bakedCanvas.requestPaint()
                        return
                    }
                    const pad = 6
                    bakedCanvas.markDirty(Qt.rect(b.x - overlay.originX - pad, b.y - overlay.originY - pad,
                                                  b.w + pad * 2, b.h + pad * 2))
                }
            }
        }

        // The stroke being drawn or dragged: the only thing repainted per
        // mouse move.
        Canvas {
            id: activeCanvas
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            tileSize: annot.tile
            visible: annot.activePoints.length > 0 || annot.dragId >= 0

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const s = ctl ? annot._previewStroke() : null
                if (!s)
                    return
                const cfg = { "offsetX": -overlay.originX - overlay.selLX, "offsetY": -overlay.originY - overlay.selLY,
                              "numberIndex": Renderer.numbering(ctl.strokes), "fontFamily": annot.canvasFont }
                if (annot.dragId < 0)
                    cfg.numberIndex[s.id] = Object.keys(cfg.numberIndex).length + 1   // the number it will get
                Renderer.drawStroke(ctx, s, cfg)
            }
        }
    }

    // ── Selection outline, never exported ────────────────────────────────────

    Canvas {
        id: selectionOutline
        readonly property int pad: 8
        visible: annot.selectedBounds !== null && annot.dragId < 0 && overlay.hasSel
        x: annot.selectedBounds ? overlay.toLocalX(annot.selectedBounds.x) - pad : 0
        y: annot.selectedBounds ? overlay.toLocalY(annot.selectedBounds.y) - pad : 0
        width: annot.selectedBounds ? annot.selectedBounds.w + pad * 2 : 1
        height: annot.selectedBounds ? annot.selectedBounds.h + pad * 2 : 1
        renderStrategy: Canvas.Cooperative

        onVisibleChanged: if (visible) requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const s = annot.selectedStroke
            if (!s)
                return
            const b = annot.selectedBounds
            Renderer.drawSelection(ctx, s, { "offsetX": -b.x + pad, "offsetY": -b.y + pad })
        }
    }

    // ── Text editor, never exported ──────────────────────────────────────────

    Item {
        id: textEditor
        readonly property int pad: 4
        visible: annot.textSession !== null
        x: annot.textSession ? overlay.toLocalX(annot.textSession.x) - pad : 0
        y: annot.textSession ? overlay.toLocalY(annot.textSession.y) - pad : 0
        width: textEdit.contentWidth + pad * 2 + 4
        height: textEdit.contentHeight + pad * 2

        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.surfaceContainer, 0.25)
            border.color: Theme.withAlpha(Theme.primary, 0.8)
            border.width: 1
            radius: 2
        }

        TextEdit {
            id: textEdit
            x: textEditor.pad
            y: textEditor.pad
            width: Math.max(8, contentWidth + 4)
            font.family: annot.canvasFont
            font.pixelSize: annot.textSession ? annot.textSession.fontSize : 24
            color: ctl ? ctl.strokeColor : "red"
            wrapMode: TextEdit.NoWrap
            textFormat: TextEdit.PlainText
            selectByMouse: true
            cursorVisible: activeFocus
            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    annot.cancelTextEdit()
                    event.accepted = true
                    return
                }
                // Enter commits; Shift+Enter falls through and inserts a newline.
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        && !(event.modifiers & Qt.ShiftModifier)) {
                    // Let the input method finish composing before committing.
                    if (inputMethodComposing)
                        Qt.inputMethod.commit()
                    Qt.callLater(annot.commitTextEdit)
                    event.accepted = true
                }
            }
        }
    }
}
