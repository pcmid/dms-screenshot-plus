import QtQuick
import qs.Common
import "lib/Renderer.js" as Renderer
import "lib/Hit.js" as Hit
import "lib/Tools.js" as Tools

// Everything that is drawn on top of the frozen frame, for one screen.
//
//   exportRoot        the subtree that becomes the exported image: a copy of
//                     the frame, the mosaic layers, the committed strokes and
//                     the stroke being drawn or dragged
//   selectionOutline  dashed frame around the selected stroke — a SIBLING of
//                     exportRoot so it is never exported
//   textEditor        the TextEdit used while typing — also a sibling
//
// All public functions take GLOBAL LOGICAL coordinates.
Item {
    id: annot

    property var overlay: null        // the PanelWindow (coordinates, selection)
    property var ctl: null        // the daemon (strokes, tool, colour)
    property var frameItem: null  // ScreencopyView or Image holding the frame

    readonly property alias exportItem: exportRoot
    readonly property bool editingText: textSession !== null
    // Stroke temporarily hidden from bakedCanvas: being dragged or edited.
    readonly property int hiddenId: dragId >= 0 ? dragId
                                  : (textSession && textSession.id >= 0 ? textSession.id : -1)

    // ── Transient state (never enters the undo history) ──────────────────────

    // The stroke being drawn.
    property string activeTool: ""
    property var activePoints: []

    // The stroke being dragged (select tool).
    property int dragId: -1
    property var dragStroke: null
    property real dragX0: 0
    property real dragY0: 0
    property real moveDx: 0
    property real moveDy: 0

    // The text being typed: { x, y, id (-1 for new), fontSize }
    property var textSession: null

    // Measured once: how far the TextEdit's first glyph row sits below its
    // top edge compared to Canvas' "top" baseline. Adjusted after eyeballing.
    readonly property real textYNudge: 0

    anchors.fill: parent

    onHiddenIdChanged: bakedCanvas.requestPaint()

    // ── Drawing API ──────────────────────────────────────────────────────────

    function beginStroke(gx, gy) {
        activeTool = ctl.activeTool
        const p = { "x": gx, "y": gy }
        activePoints = Tools.kindOf(activeTool) === "drag" ? [p, p] : [p]
        activeCanvas.requestPaint()
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
        activeCanvas.requestPaint()
    }

    function endStroke() {
        const pts = activePoints
        const tool = activeTool
        activePoints = []
        activeTool = ""
        activeCanvas.requestPaint()
        if (pts.length === 0)
            return
        if (Tools.kindOf(tool) === "drag") {
            const dx = pts[1].x - pts[0].x, dy = pts[1].y - pts[0].y
            if (dx * dx + dy * dy < 4)
                return // a click, not a drag
        }
        ctl.pushStroke({
            "tool": tool,
            "color": String(ctl.strokeColor),
            "width": ctl.currentWidth,
            "points": pts
        })
    }

    // ── Move API (select tool) ───────────────────────────────────────────────

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
        activeCanvas.requestPaint()
    }

    function updateMove(gx, gy) {
        if (dragId < 0)
            return
        moveDx = gx - dragX0
        moveDy = gy - dragY0
        activeCanvas.requestPaint()
    }

    function endMove() {
        if (dragId < 0)
            return
        const id = dragId, s = dragStroke, dx = moveDx, dy = moveDy
        dragId = -1
        dragStroke = null
        moveDx = 0
        moveDy = 0
        activeCanvas.requestPaint()
        if (dx !== 0 || dy !== 0)
            ctl.replaceStroke(id, Hit.translate(s, dx, dy))
    }

    // ── Text API ─────────────────────────────────────────────────────────────

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
        ctl.textEditing = true
        textEdit.cursorPosition = textEdit.length
        textEdit.forceActiveFocus()
    }

    function commitTextEdit() {
        const s = textSession
        if (!s)
            return
        const text = textEdit.text
        const lines = Math.max(1, textEdit.lineCount)
        const stroke = {
            "tool": "text",
            "color": String(ctl.strokeColor),
            "width": s.fontSize,
            "points": [{ "x": s.x, "y": s.y }],
            "text": text,
            "w": Math.ceil(textEdit.contentWidth),
            "h": Math.ceil(textEdit.contentHeight),
            "lineHeight": textEdit.contentHeight / lines,
            "font": textEdit.font.family
        }
        _endTextSession()
        if (text.trim() === "") {
            if (s.id >= 0)
                ctl.deleteStroke(s.id)
            return
        }
        if (s.id >= 0)
            ctl.replaceStroke(s.id, stroke)
        else
            ctl.pushStroke(stroke)
    }

    function cancelTextEdit() {
        if (!textSession)
            return
        _endTextSession()
    }

    function _endTextSession() {
        textSession = null
        textEdit.text = ""
        ctl.textEditing = false
        if (overlay && overlay.keyHandler)
            overlay.keyHandler.forceActiveFocus()
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    readonly property var mosaics: ctl ? ctl.strokes.filter(s => s.tool === "mosaic") : []
    readonly property var selectedStroke: {
        if (!ctl || ctl.selectedId < 0)
            return null
        const i = Hit.indexOfId(ctl.strokes, ctl.selectedId)
        return i === -1 ? null : ctl.strokes[i]
    }
    readonly property var selectedBounds: selectedStroke ? Hit.bounds(selectedStroke) : null

    // ── exportRoot: what gets exported ───────────────────────────────────────

    Item {
        id: exportRoot

        x: overlay.selLX
        y: overlay.selLY
        width: overlay.selLW
        height: overlay.selLH
        clip: true
        visible: overlay.hasSel && overlay.frameReady

        // Frame copy, re-using whichever item already holds the texture — no
        // second capture and no second PNG decode, whatever the backend.
        // textureSize pins the copy to source pixels so the grab samples at
        // full resolution rather than at the on-screen size.
        ShaderEffectSource {
            anchors.fill: parent
            sourceItem: annot.frameItem
            sourceRect: Qt.rect(overlay.selLX, overlay.selLY, overlay.selLW, overlay.selLH)
            textureSize: Qt.size(Math.max(1, Math.round(overlay.selLW * overlay.outScale)),
                                 Math.max(1, Math.round(overlay.selLH * overlay.outScale)))
            live: true
            recursive: false
        }

        // Mosaic: a tiny re-render of the frame region, then nearest-neighbour
        // upscaling. Works with both backends and needs no pixel access.
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

        // Live preview while dragging out a mosaic.
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

        // Committed strokes. Full-screen sized but positioned relative to the
        // clip item, so stroke coordinates stay independent of the selection.
        Canvas {
            id: bakedCanvas
            x: -overlay.selLX
            y: -overlay.selLY
            width: overlay.width
            height: overlay.height
            renderStrategy: Canvas.Cooperative

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (!ctl)
                    return
                Renderer.drawAll(ctx, ctl.strokes, {
                    "offsetX": -overlay.originX, "offsetY": -overlay.originY,
                    "excludeId": annot.hiddenId, "fontFamily": Theme.fontFamily
                })
            }

            Connections {
                target: ctl
                function onStrokesChanged() { bakedCanvas.requestPaint() }
            }
        }

        // The stroke being drawn, or the one being dragged — the only thing
        // that repaints per mouse move.
        Canvas {
            id: activeCanvas
            x: -overlay.selLX
            y: -overlay.selLY
            width: overlay.width
            height: overlay.height
            renderStrategy: Canvas.Cooperative
            visible: annot.activePoints.length > 0 || annot.dragId >= 0

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (!ctl)
                    return
                const cfg = { "offsetX": -overlay.originX, "offsetY": -overlay.originY,
                              "numberIndex": Renderer.numbering(ctl.strokes), "fontFamily": Theme.fontFamily }
                if (annot.dragId >= 0 && annot.dragStroke) {
                    Renderer.drawStroke(ctx, Hit.translate(annot.dragStroke, annot.moveDx, annot.moveDy), cfg)
                } else if (annot.activePoints.length > 0 && annot.activeTool !== "mosaic") {
                    // A number being placed gets the index it will receive.
                    const preview = { "id": ctl.nextStrokeId, "tool": annot.activeTool,
                                      "color": String(ctl.strokeColor), "width": ctl.currentWidth,
                                      "points": annot.activePoints }
                    cfg.numberIndex[preview.id] = Object.keys(cfg.numberIndex).length + 1
                    Renderer.drawStroke(ctx, preview, cfg)
                }
            }
        }
    }

    // ── Selection outline (never exported) ───────────────────────────────────

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

    // ── Text editor (never exported) ─────────────────────────────────────────

    Item {
        id: textEditor
        readonly property int pad: 4
        visible: annot.textSession !== null
        x: annot.textSession ? overlay.toLocalX(annot.textSession.x) - pad : 0
        y: annot.textSession ? overlay.toLocalY(annot.textSession.y) - pad + annot.textYNudge : 0
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
            font.family: Theme.fontFamily
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
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        && !(event.modifiers & Qt.ShiftModifier)) {
                    // Let the input method finish composing before we commit,
                    // or a half-typed CJK candidate is lost.
                    if (inputMethodComposing)
                        Qt.inputMethod.commit()
                    Qt.callLater(annot.commitTextEdit)
                    event.accepted = true
                }
                // Shift+Enter falls through: TextEdit inserts a newline.
            }
        }
    }
}
