import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import "lib/Renderer.js" as Renderer

// One fullscreen layer-shell window per monitor. Everything lives in the same
// QML scene, which is the whole point: the toolbar and the annotations are
// bound to the selection rectangle, so dragging the selection moves them for
// free — no synchronisation code anywhere.
Variants {
    id: root

    property var ctl: null

    model: Quickshell.screens

    delegate: PanelWindow {
        id: win

        required property var modelData
        screen: modelData

        visible: root.ctl ? root.ctl.active : false
        color: "transparent"

        WlrLayershell.namespace: "dms:screenshot-plus"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusiveZone: -1
        // TODO(multi-monitor): several Exclusive layers compete for the keyboard.
        // Fine for a single screen; revisit when multi-monitor lands.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        anchors {
            left: true
            right: true
            top: true
            bottom: true
        }

        // ── Coordinate mapping ───────────────────────────────────────────────
        // Global logical -> this screen's local logical is a subtraction.

        readonly property string screenName: modelData.name
        readonly property var info: (root.ctl && root.ctl.screenInfo[screenName]) || null
        readonly property real originX: info ? info.x : modelData.x
        readonly property real originY: info ? info.y : modelData.y
        readonly property real outScale: info ? info.scale : 1
        readonly property string freezePath: (root.ctl && root.ctl.freezes[screenName]) || ""
        readonly property string freezeUrl: freezePath ? "file://" + freezePath : ""

        readonly property bool useScreencopy: root.ctl && root.ctl.backend === "screencopy"

        // Two distinct milestones, and conflating them costs ~170ms of felt latency:
        //
        //   dimmable  — the grab has RETURNED, so painting the dimmer can no
        //               longer contaminate it. The frozen PNG may still be
        //               decoding, but the live desktop showing through is the
        //               same picture, so dimming now is visually seamless.
        //   frameReady — the frame is actually decoded and on screen. Only the
        //               export has to wait for this.
        readonly property bool dimmable: root.ctl && !root.ctl.capturing

        readonly property bool frameReady: useScreencopy
                                          ? frozen.hasContent
                                          : (win.freezeUrl !== "" && freezeImage.status === Image.Ready)

        onFrameReadyChanged: {
            if (frameReady && root.ctl)
                root.ctl.noteFrameReady()
        }

        function toGlobalX(lx) { return lx + originX }
        function toGlobalY(ly) { return ly + originY }
        function toLocalX(gx) { return gx - originX }
        function toLocalY(gy) { return gy - originY }

        // Selection in this screen's local coords, for drawing.
        readonly property real selLX: root.ctl ? toLocalX(root.ctl.selX) : 0
        readonly property real selLY: root.ctl ? toLocalY(root.ctl.selY) : 0
        readonly property real selLW: root.ctl ? root.ctl.selW : 0
        readonly property real selLH: root.ctl ? root.ctl.selH : 0
        readonly property bool hasSel: root.ctl ? root.ctl.hasSelection : false

        // The screen containing the selection centre owns keyboard actions and export.
        readonly property bool ownsSelection: {
            if (!root.ctl || !root.ctl.hasSelection)
                return true // before a selection exists, everyone listens
            const cx = root.ctl.selX + root.ctl.selW / 2
            const cy = root.ctl.selY + root.ctl.selH / 2
            return cx >= originX && cx < originX + modelData.width
                && cy >= originY && cy < originY + modelData.height
        }

        // ── Interaction state ────────────────────────────────────────────────

        property string mode: "idle" // idle | creating | moving | resizing | drawing
        property string resizeHandle: ""
        property real dragGX: 0
        property real dragGY: 0
        property var origSel: null
        property var activePoints: []

        readonly property int handleSize: 10
        readonly property int minSel: 8

        function snapshotSel() {
            return {
                "x": root.ctl.selX,
                "y": root.ctl.selY,
                "w": root.ctl.selW,
                "h": root.ctl.selH
            }
        }

        function clampToLayout(gx, gy) {
            // Prototype: single screen, so clamp to this screen's bounds.
            return {
                "x": Math.max(originX, Math.min(originX + modelData.width, gx)),
                "y": Math.max(originY, Math.min(originY + modelData.height, gy))
            }
        }

        function beginDrag(gx, gy) {
            dragGX = gx
            dragGY = gy
            origSel = snapshotSel()
        }

        function insideSel(gx, gy) {
            return hasSel
                && gx >= root.ctl.selX && gx <= root.ctl.selX + root.ctl.selW
                && gy >= root.ctl.selY && gy <= root.ctl.selY + root.ctl.selH
        }

        function applyResize(gx, gy) {
            const o = origSel
            if (!o)
                return

            let l = o.x
            let t = o.y
            let r = o.x + o.w
            let b = o.y + o.h

            if (resizeHandle.indexOf("l") !== -1) l = gx
            if (resizeHandle.indexOf("r") !== -1) r = gx
            if (resizeHandle.indexOf("t") !== -1) t = gy
            if (resizeHandle.indexOf("b") !== -1) b = gy

            root.ctl.setSelection(Math.min(l, r), Math.min(t, b),
                                  Math.abs(r - l), Math.abs(b - t))
        }

        function commitStroke() {
            if (activePoints.length === 0)
                return
            root.ctl.pushStroke({
                                    "tool": root.ctl.activeTool,
                                    "color": String(root.ctl.strokeColor),
                                    "width": root.ctl.strokeWidth,
                                    "points": activePoints.slice()
                                })
            activePoints = []
        }

        // ── Frozen frame ─────────────────────────────────────────────────────

        // Two ways to get one: the GPU texture (instant) or a PNG off disk
        // (~180ms). Only one is live at a time.

        ScreencopyView {
            id: frozen
            anchors.fill: parent
            visible: win.useScreencopy
            // Only bind the source once the window exists, and never in CLI mode.
            captureSource: (win.useScreencopy && win.visible) ? win.modelData : null
            // A single frame. Staying live would capture our own overlay back
            // into itself the moment the dimmer appears.
            live: false
            paintCursor: false
        }

        Image {
            id: freezeImage
            anchors.fill: parent
            visible: !win.useScreencopy
            source: win.useScreencopy ? "" : win.freezeUrl
            fillMode: Image.Stretch
            smooth: true
            cache: false
            // Decode off the UI thread. The overlay is already mapped and the
            // dimmer is already up, so there is no empty frame to flash — and
            // a 4.8MB/3840x2160 PNG blocks the render thread for ~170ms if
            // decoded synchronously.
            asynchronous: true
        }

        // ── Dimming outside the selection (4 rects beats a canvas at 4K) ─────

        Item {
            anchors.fill: parent
            visible: win.dimmable

            // Functional colours, not theme colours: a screenshot dimmer must be
            // neutral black regardless of the user's accent or light/dark mode.
            readonly property color dim: Qt.rgba(0, 0, 0, 0.45)

            Rectangle { // top
                color: parent.dim
                x: 0; y: 0
                width: parent.width
                height: win.hasSel ? Math.max(0, win.selLY) : parent.height
            }
            Rectangle { // bottom
                color: parent.dim
                visible: win.hasSel
                x: 0
                y: win.selLY + win.selLH
                width: parent.width
                height: Math.max(0, parent.height - (win.selLY + win.selLH))
            }
            Rectangle { // left
                color: parent.dim
                visible: win.hasSel
                x: 0
                y: win.selLY
                width: Math.max(0, win.selLX)
                height: win.selLH
            }
            Rectangle { // right
                color: parent.dim
                visible: win.hasSel
                x: win.selLX + win.selLW
                y: win.selLY
                width: Math.max(0, parent.width - (win.selLX + win.selLW))
                height: win.selLH
            }
        }

        // ── Selection contents: frame copy + annotations ─────────────────────
        //
        // This subtree IS the exported image. It holds its own copy of the
        // frozen frame underneath the strokes, so grabToImage() on it yields
        // exactly the selection — no cropping maths, no Canvas image plumbing.
        // Visually it sits pixel-on-pixel over the full-screen frame below it,
        // so nothing looks different.
        //
        // The selection decorations (border, handles, toolbar) are siblings,
        // not children, so they are never captured.

        Item {
            id: exportRoot

            x: win.selLX
            y: win.selLY
            width: win.selLW
            height: win.selLH
            clip: true
            visible: win.hasSel && win.frameReady

            // Frame copy, re-using whichever item already holds the texture —
            // no second capture and no second PNG decode, whatever the backend.
            // textureSize pins the copy to source pixels so the grab below
            // samples at full resolution rather than at the on-screen size.
            ShaderEffectSource {
                anchors.fill: parent
                sourceItem: win.useScreencopy ? frozen : freezeImage
                sourceRect: Qt.rect(win.selLX, win.selLY, win.selLW, win.selLH)
                textureSize: Qt.size(Math.max(1, Math.round(win.selLW * win.outScale)),
                                     Math.max(1, Math.round(win.selLH * win.outScale)))
                live: true
                recursive: false
            }

            Canvas {
                id: bakedCanvas
                // Full-screen sized but positioned relative to the clip item, so
                // stroke coordinates stay independent of the selection.
                x: -win.selLX
                y: -win.selLY
                width: win.width
                height: win.height
                renderStrategy: Canvas.Cooperative

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    if (!root.ctl)
                        return
                    Renderer.drawAll(ctx, root.ctl.strokes, {
                                         "offsetX": -win.originX,
                                         "offsetY": -win.originY,
                                         "scale": 1
                                     })
                }

                Connections {
                    target: root.ctl
                    function onStrokesChanged() { bakedCanvas.requestPaint() }
                }
            }

            // Live preview of the stroke being drawn.
            // Rect gets a cheap Rectangle; pen needs a canvas (the hot path).
            Rectangle {
                visible: win.mode === "drawing" && root.ctl.activeTool === "rect"
                         && win.activePoints.length >= 2
                color: "transparent"
                border.color: root.ctl ? root.ctl.strokeColor : "red"
                border.width: root.ctl ? root.ctl.strokeWidth : 3
                x: win.activePoints.length >= 2
                   ? win.toLocalX(Math.min(win.activePoints[0].x, win.activePoints[1].x)) - win.selLX : 0
                y: win.activePoints.length >= 2
                   ? win.toLocalY(Math.min(win.activePoints[0].y, win.activePoints[1].y)) - win.selLY : 0
                width: win.activePoints.length >= 2
                       ? Math.abs(win.activePoints[1].x - win.activePoints[0].x) : 0
                height: win.activePoints.length >= 2
                        ? Math.abs(win.activePoints[1].y - win.activePoints[0].y) : 0
            }

            Canvas {
                id: activeCanvas
                x: -win.selLX
                y: -win.selLY
                width: win.width
                height: win.height
                renderStrategy: Canvas.Cooperative
                visible: win.mode === "drawing" && root.ctl.activeTool === "pen"

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    if (!root.ctl || win.activePoints.length === 0)
                        return
                    Renderer.drawStroke(ctx, {
                                            "tool": root.ctl.activeTool,
                                            "color": String(root.ctl.strokeColor),
                                            "width": root.ctl.strokeWidth,
                                            "points": win.activePoints
                                        }, {
                                            "offsetX": -win.originX,
                                            "offsetY": -win.originY,
                                            "scale": 1
                                        })
                }
            }
        }

        // ── Selection border + size readout ──────────────────────────────────

        Rectangle {
            visible: win.hasSel && win.dimmable
            x: win.selLX
            y: win.selLY
            width: win.selLW
            height: win.selLH
            color: "transparent"
            border.color: Theme.primary
            border.width: 1
        }

        Rectangle {
            visible: win.hasSel && win.dimmable && win.selLW > 0
            color: Theme.withAlpha(Theme.surfaceContainer, 0.9)
            radius: Theme.cornerRadiusSmall
            border.color: Theme.withAlpha(Theme.outline, 0.3)
            border.width: 1
            width: sizeLabel.implicitWidth + Theme.spacingM
            height: sizeLabel.implicitHeight + Theme.spacingXS
            x: Math.max(0, Math.min(win.width - width, win.selLX))
            y: win.selLY - height - Theme.spacingXS > 0
               ? win.selLY - height - Theme.spacingXS
               : win.selLY + Theme.spacingXS

            Text {
                id: sizeLabel
                anchors.centerIn: parent
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                text: Math.round(win.selLW) + " × " + Math.round(win.selLH)
                      + "  (" + Math.round(win.selLW * win.outScale)
                      + " × " + Math.round(win.selLH * win.outScale) + " px)"
            }
        }

        // ── Main pointer handling ────────────────────────────────────────────

        MouseArea {
            id: mainArea
            anchors.fill: parent
            // Deliberately live before the frame arrives — the point of mapping
            // early is that dragging out a selection never has to wait.
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            cursorShape: {
                if (win.mode === "drawing" || (root.ctl && root.ctl.activeTool !== ""))
                    return Qt.CrossCursor
                if (win.mode === "moving")
                    return Qt.ClosedHandCursor
                if (win.hasSel && win.insideSel(win.toGlobalX(mouseX), win.toGlobalY(mouseY)))
                    return Qt.OpenHandCursor
                return Qt.CrossCursor
            }

            onPressed: mouse => {
                if (mouse.button === Qt.RightButton) {
                    // Right click clears the tool, or cancels if none is active.
                    if (root.ctl.activeTool !== "")
                        root.ctl.activeTool = ""
                    else
                        root.ctl.cancel()
                    return
                }

                const gx = win.toGlobalX(mouse.x)
                const gy = win.toGlobalY(mouse.y)

                if (root.ctl.activeTool !== "" && win.insideSel(gx, gy)) {
                    win.mode = "drawing"
                    win.activePoints = root.ctl.activeTool === "rect"
                        ? [{"x": gx, "y": gy}, {"x": gx, "y": gy}]
                        : [{"x": gx, "y": gy}]
                    activeCanvas.requestPaint()
                } else if (win.insideSel(gx, gy)) {
                    win.mode = "moving"
                    win.beginDrag(gx, gy)
                } else {
                    win.mode = "creating"
                    win.beginDrag(gx, gy)
                    root.ctl.setSelection(gx, gy, 0, 0)
                }
            }

            onPositionChanged: mouse => {
                if (win.mode === "idle")
                    return

                const c = win.clampToLayout(win.toGlobalX(mouse.x), win.toGlobalY(mouse.y))
                const gx = c.x
                const gy = c.y

                switch (win.mode) {
                case "creating":
                    root.ctl.setSelection(Math.min(win.dragGX, gx), Math.min(win.dragGY, gy),
                                          Math.abs(gx - win.dragGX), Math.abs(gy - win.dragGY))
                    break

                case "moving": {
                    const o = win.origSel
                    root.ctl.setSelection(o.x + (gx - win.dragGX), o.y + (gy - win.dragGY), o.w, o.h)
                    break
                }

                case "drawing": {
                    const pts = win.activePoints.slice()
                    if (root.ctl.activeTool === "rect")
                        pts[1] = {"x": gx, "y": gy}
                    else
                        pts.push({"x": gx, "y": gy})
                    win.activePoints = pts
                    if (root.ctl.activeTool === "pen")
                        activeCanvas.requestPaint()
                    break
                }
                }
            }

            onReleased: mouse => {
                if (mouse.button === Qt.RightButton)
                    return

                if (win.mode === "drawing") {
                    win.commitStroke()
                } else if (win.mode === "creating" && root.ctl.selW < win.minSel
                           && root.ctl.selH < win.minSel) {
                    // A click, not a drag — discard the sliver.
                    root.ctl.setSelection(0, 0, 0, 0)
                }
                win.mode = "idle"
                win.resizeHandle = ""
            }
        }

        // ── Resize handles ───────────────────────────────────────────────────

        Repeater {
            model: win.hasSel && win.dimmable && root.ctl && root.ctl.activeTool === ""
                   ? ["tl", "t", "tr", "r", "br", "b", "bl", "l"] : []

            delegate: Rectangle {
                id: handle
                required property string modelData

                readonly property real hx: {
                    if (modelData.indexOf("l") !== -1) return win.selLX
                    if (modelData.indexOf("r") !== -1) return win.selLX + win.selLW
                    return win.selLX + win.selLW / 2
                }
                readonly property real hy: {
                    if (modelData.indexOf("t") !== -1) return win.selLY
                    if (modelData.indexOf("b") !== -1) return win.selLY + win.selLH
                    return win.selLY + win.selLH / 2
                }

                width: win.handleSize
                height: win.handleSize
                radius: width / 2
                x: hx - width / 2
                y: hy - height / 2
                color: Theme.primary
                border.color: Theme.surface
                border.width: 1

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6 // easier to grab than the dot suggests
                    cursorShape: {
                        switch (handle.modelData) {
                        case "tl": case "br": return Qt.SizeFDiagCursor
                        case "tr": case "bl": return Qt.SizeBDiagCursor
                        case "t": case "b": return Qt.SizeVerCursor
                        default: return Qt.SizeHorCursor
                        }
                    }

                    onPressed: mouse => {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        win.mode = "resizing"
                        win.resizeHandle = handle.modelData
                        win.beginDrag(win.toGlobalX(p.x), win.toGlobalY(p.y))
                    }

                    onPositionChanged: mouse => {
                        if (win.mode !== "resizing")
                            return
                        const p = mapToItem(null, mouse.x, mouse.y)
                        const c = win.clampToLayout(win.toGlobalX(p.x), win.toGlobalY(p.y))
                        win.applyResize(c.x, c.y)
                    }

                    onReleased: {
                        win.mode = "idle"
                        win.resizeHandle = ""
                    }
                }
            }
        }

        // ── Toolbar (bound to the selection — this is the whole feature) ─────

        Rectangle {
            id: toolbar

            readonly property int gap: Theme.spacingS
            readonly property int pad: Theme.spacingS

            visible: win.hasSel && win.dimmable && win.ownsSelection && win.mode !== "creating"
            width: toolRow.implicitWidth + Theme.spacingM * 2
            height: toolRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.color: Theme.withAlpha(Theme.outline, 0.2)
            border.width: 1

            // Right-aligned with the selection, clamped to the screen.
            x: Math.max(pad, Math.min(win.width - width - pad,
                                      win.selLX + win.selLW - width))
            // Below the selection; flip above when there's no room; last resort
            // is tucking it inside the selection's bottom edge.
            y: (win.selLY + win.selLH + gap + height < win.height)
               ? win.selLY + win.selLH + gap
               : ((win.selLY - gap - height > 0)
                  ? win.selLY - gap - height
                  : Math.max(pad, win.selLY + win.selLH - height - gap))

            Row {
                id: toolRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                Repeater {
                    model: [
                        {"id": "rect", "label": "▭", "tip": "矩形"},
                        {"id": "pen", "label": "✎", "tip": "画笔"},
                        {"id": "|", "label": "", "tip": ""},
                        {"id": "undo", "label": "↶", "tip": "撤销"},
                        {"id": "redo", "label": "↷", "tip": "重做"},
                        {"id": "|", "label": "", "tip": ""},
                        {"id": "cancel", "label": "✕", "tip": "取消"},
                        {"id": "done", "label": "✓", "tip": "复制到剪贴板"}
                    ]

                    delegate: Item {
                        required property var modelData

                        readonly property bool isSep: modelData.id === "|"
                        readonly property bool isTool: modelData.id === "rect" || modelData.id === "pen"
                        readonly property bool isActive: isTool && root.ctl.activeTool === modelData.id
                        readonly property bool isEnabled: {
                            if (modelData.id === "undo") return root.ctl.canUndo
                            if (modelData.id === "redo") return root.ctl.canRedo
                            return true
                        }

                        width: isSep ? 1 : 30
                        height: 28

                        Rectangle {
                            visible: parent.isSep
                            anchors.centerIn: parent
                            width: 1
                            height: 18
                            color: Theme.withAlpha(Theme.outline, 0.3)
                        }

                        Rectangle {
                            visible: !parent.isSep
                            anchors.fill: parent
                            radius: Theme.cornerRadiusSmall
                            color: {
                                if (parent.isActive)
                                    return Theme.withAlpha(Theme.primary, 0.25)
                                if (btnArea.containsMouse && parent.isEnabled)
                                    return Theme.withAlpha(Theme.primary, 0.12)
                                return "transparent"
                            }

                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeMedium
                                color: {
                                    if (!isEnabled)
                                        return Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                                    if (modelData.id === "done")
                                        return Theme.success
                                    if (modelData.id === "cancel")
                                        return Theme.error
                                    if (isActive)
                                        return Theme.primary
                                    return Theme.surfaceText
                                }
                            }

                            MouseArea {
                                id: btnArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: isEnabled
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    switch (modelData.id) {
                                    case "rect":
                                    case "pen":
                                        root.ctl.activeTool =
                                            root.ctl.activeTool === modelData.id ? "" : modelData.id
                                        break
                                    case "undo":
                                        root.ctl.undo()
                                        break
                                    case "redo":
                                        root.ctl.redo()
                                        break
                                    case "cancel":
                                        root.ctl.cancel()
                                        break
                                    case "done":
                                        root.ctl.finish()
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Hint before a selection exists ───────────────────────────────────

        Text {
            visible: !win.hasSel && win.ownsSelection && win.dimmable
            anchors.centerIn: parent
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeLarge
            text: "拖动选择区域  ·  Esc 取消"
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.6)
        }

        // ── Keyboard ─────────────────────────────────────────────────────────

        Item {
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (!root.ctl)
                    return

                if (event.key === Qt.Key_Escape) {
                    if (root.ctl.activeTool !== "")
                        root.ctl.activeTool = ""
                    else
                        root.ctl.cancel()
                    event.accepted = true
                    return
                }

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.ctl.finish()
                    event.accepted = true
                    return
                }

                if (event.modifiers & Qt.ControlModifier) {
                    switch (event.key) {
                    case Qt.Key_C:
                        root.ctl.finish()
                        event.accepted = true
                        return
                    case Qt.Key_Z:
                        if (event.modifiers & Qt.ShiftModifier)
                            root.ctl.redo()
                        else
                            root.ctl.undo()
                        event.accepted = true
                        return
                    case Qt.Key_Y:
                        root.ctl.redo()
                        event.accepted = true
                        return
                    }
                }

                // Tool shortcuts
                if (event.key === Qt.Key_R) {
                    root.ctl.activeTool = root.ctl.activeTool === "rect" ? "" : "rect"
                    event.accepted = true
                } else if (event.key === Qt.Key_P) {
                    root.ctl.activeTool = root.ctl.activeTool === "pen" ? "" : "pen"
                    event.accepted = true
                }
            }
        }

        // ── Export ───────────────────────────────────────────────────────────
        // grabToImage renders exportRoot's subtree at the requested pixel size,
        // so asking for selection × scale samples the frame texture at its full
        // native resolution. The selection decorations are siblings of
        // exportRoot and stay out of the picture.

        function doExport() {
            const s = win.outScale
            // grabToImage's targetSize is in LOGICAL units — Qt multiplies it by
            // the window's devicePixelRatio on the way to pixels. Divide it back
            // out, or a 2x screen yields an image at twice the intended size.
            // outScale and dpr differ under fractional scaling (dpr reports the
            // integer buffer scale), so both are needed.
            const d = modelData.devicePixelRatio || 1
            const w = Math.max(1, Math.round(root.ctl.selW * s / d))
            const h = Math.max(1, Math.round(root.ctl.selH * s / d))
            const path = "/tmp/dmsplus_" + Date.now() + ".png"

            const ok = exportRoot.grabToImage(result => {
                if (!result.saveToFile(path)) {
                    console.warn("screenshotPlus: saveToFile failed for", path)
                    root.ctl.cancel()
                    return
                }
                root.ctl.onExported(path)
            }, Qt.size(w, h))

            if (!ok) {
                console.warn("screenshotPlus: grabToImage refused")
                root.ctl.cancel()
            }
        }

        Connections {
            target: root.ctl
            function onExportRequested() {
                if (win.ownsSelection)
                    win.doExport()
            }
        }
    }
}
