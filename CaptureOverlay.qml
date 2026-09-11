import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import "lib/Tools.js" as Tools

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
        // Exclusive so Esc/Enter/Ctrl+Z/tool keys reach us; released while the
        // colour picker (a separate window) needs to be typed into.
        WlrLayershell.keyboardFocus: (root.ctl && root.ctl.pickerOpen) ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive

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

        // Two distinct milestones:
        //   dimmable   — the grab has RETURNED, so painting the dimmer can no
        //                longer contaminate it. The live desktop underneath is
        //                the same picture, so dimming now is seamless.
        //   frameReady — the frame is decoded and on screen. Export waits for it.
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
                return true
            const cx = root.ctl.selX + root.ctl.selW / 2
            const cy = root.ctl.selY + root.ctl.selH / 2
            return cx >= originX && cx < originX + modelData.width
                && cy >= originY && cy < originY + modelData.height
        }

        readonly property alias keyHandler: keyHandler

        // ── Interaction state ────────────────────────────────────────────────

        // idle | creating | moving | resizing | drawing | dragStroke
        property string mode: "idle"
        property string resizeHandle: ""
        property real dragGX: 0
        property real dragGY: 0
        property var origSel: null

        readonly property int handleSize: 10
        readonly property int minSel: 8
        readonly property string toolKind: root.ctl ? Tools.kindOf(root.ctl.activeTool) : ""

        function snapshotSel() {
            return { "x": root.ctl.selX, "y": root.ctl.selY, "w": root.ctl.selW, "h": root.ctl.selH }
        }

        function clampToLayout(gx, gy) {
            // Single screen for now: clamp to this screen's bounds.
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
            let l = o.x, t = o.y, r = o.x + o.w, b = o.y + o.h
            if (resizeHandle.indexOf("l") !== -1) l = gx
            if (resizeHandle.indexOf("r") !== -1) r = gx
            if (resizeHandle.indexOf("t") !== -1) t = gy
            if (resizeHandle.indexOf("b") !== -1) b = gy
            root.ctl.setSelection(Math.min(l, r), Math.min(t, b), Math.abs(r - l), Math.abs(b - t))
        }

        // Esc / right click: peel one layer of state at a time.
        function peelBack() {
            if (annot.editingText)
                annot.cancelTextEdit()
            else if (root.ctl.selectedId >= 0)
                root.ctl.select(-1)
            else if (root.ctl.activeTool !== "")
                root.ctl.activeTool = ""
            else
                root.ctl.cancel()
        }

        // ── Colour picker (a separate DMS window) ────────────────────────────
        // It lives on the Top layer and gets no keyboard while screenshotActive
        // is set, so: lift it to Overlay, drop our own grab, and undo both when
        // it closes. Same dance quickCapture does.

        function openPicker() {
            const p = PopoutService.colorPickerModal
            if (!p) {
                console.warn("screenshotPlus: colorPickerModal unavailable")
                return
            }
            p.useOverlayLayer = true
            p.selectedColor = root.ctl.strokeColor
            p.pickerTitle = "标注颜色"
            p.onColorSelectedCallback = c => { root.ctl.strokeColor = c }
            root.ctl.pickerOpen = true
            p.show()
        }

        Connections {
            target: PopoutService.colorPickerModal
            ignoreUnknownSignals: true
            function onDialogClosed() {
                if (!root.ctl || !root.ctl.pickerOpen)
                    return
                PopoutService.colorPickerModal.useOverlayLayer = false
                root.ctl.pickerOpen = false
                PopoutManager.screenshotActive = root.ctl.active
                keyHandler.forceActiveFocus()
            }
        }

        // ── Frozen frame ─────────────────────────────────────────────────────

        ScreencopyView {
            id: frozen
            anchors.fill: parent
            visible: win.useScreencopy
            captureSource: (win.useScreencopy && win.visible) ? win.modelData : null
            // A single frame; staying live would capture our own overlay.
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
            // Decode off the UI thread: the dimmer is already up, so nothing
            // flashes, and a 4K PNG blocks the render thread ~170ms otherwise.
            asynchronous: true
        }

        // ── Dimming outside the selection (4 rects beats a canvas at 4K) ─────

        Item {
            anchors.fill: parent
            visible: win.dimmable
            // Functional colour, not a theme colour: a screenshot dimmer must be
            // neutral black regardless of accent or light/dark mode.
            readonly property color dim: Qt.rgba(0, 0, 0, 0.45)

            Rectangle { color: parent.dim; x: 0; y: 0; width: parent.width
                        height: win.hasSel ? Math.max(0, win.selLY) : parent.height }
            Rectangle { color: parent.dim; visible: win.hasSel; x: 0; y: win.selLY + win.selLH
                        width: parent.width; height: Math.max(0, parent.height - (win.selLY + win.selLH)) }
            Rectangle { color: parent.dim; visible: win.hasSel; x: 0; y: win.selLY
                        width: Math.max(0, win.selLX); height: win.selLH }
            Rectangle { color: parent.dim; visible: win.hasSel; x: win.selLX + win.selLW; y: win.selLY
                        width: Math.max(0, parent.width - (win.selLX + win.selLW)); height: win.selLH }
        }

        // ── Annotations (export subtree + outline + text editor) ─────────────

        AnnotationLayer {
            id: annot
            overlay: win
            ctl: root.ctl
            frameItem: win.useScreencopy ? frozen : freezeImage
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
            y: win.selLY - height - Theme.spacingXS > 0 ? win.selLY - height - Theme.spacingXS
                                                        : win.selLY + Theme.spacingXS

            Text {
                id: sizeLabel
                anchors.centerIn: parent
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                text: Math.round(win.selLW) + " × " + Math.round(win.selLH)
                      + "  (" + Math.round(win.selLW * win.outScale) + " × " + Math.round(win.selLH * win.outScale) + " px)"
            }
        }

        // ── Main pointer handling ────────────────────────────────────────────

        MouseArea {
            id: mainArea
            anchors.fill: parent
            // Live before the frame arrives: dragging out a selection never waits.
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            cursorShape: {
                if (win.mode === "moving")
                    return Qt.ClosedHandCursor
                if (win.mode === "dragStroke")
                    return Qt.SizeAllCursor
                if (win.hasSel && win.insideSel(win.toGlobalX(mouseX), win.toGlobalY(mouseY))) {
                    switch (win.toolKind) {
                    case "select": return Qt.ArrowCursor
                    case "text": return Qt.IBeamCursor
                    case "": return Qt.OpenHandCursor
                    default: return Qt.CrossCursor
                    }
                }
                return Qt.CrossCursor
            }

            onPressed: mouse => {
                if (toolbarLoader.item)
                    toolbarLoader.item.closePanel()

                if (mouse.button === Qt.RightButton) {
                    win.peelBack()
                    return
                }

                const gx = win.toGlobalX(mouse.x)
                const gy = win.toGlobalY(mouse.y)
                const inside = win.insideSel(gx, gy)
                const kind = win.toolKind

                // Clicking anywhere but into the text tool's own area commits.
                if (annot.editingText && !(kind === "text" && inside))
                    annot.commitTextEdit()

                if (kind === "" || !inside) {
                    if (inside) {
                        win.mode = "moving"
                        win.beginDrag(gx, gy)
                    } else {
                        root.ctl.select(-1)
                        win.mode = "creating"
                        win.beginDrag(gx, gy)
                        root.ctl.setSelection(gx, gy, 0, 0)
                    }
                    return
                }

                switch (kind) {
                case "drag":
                case "path":
                    win.mode = "drawing"
                    annot.beginStroke(gx, gy)
                    break
                case "click":
                    annot.beginStroke(gx, gy)
                    annot.endStroke()
                    break
                case "text":
                    annot.beginTextEdit(gx, gy, null)
                    break
                case "select": {
                    const s = annot.hitAt(gx, gy)
                    root.ctl.select(s ? s.id : -1)
                    if (s) {
                        win.mode = "dragStroke"
                        annot.beginMove(s, gx, gy)
                    }
                    break
                }
                }
            }

            onDoubleClicked: mouse => {
                if (mouse.button !== Qt.LeftButton || win.toolKind !== "select")
                    return
                const s = annot.hitAt(win.toGlobalX(mouse.x), win.toGlobalY(mouse.y))
                if (s && s.tool === "text") {
                    if (win.mode === "dragStroke")
                        annot.endMove()
                    win.mode = "idle"
                    annot.beginTextEdit(0, 0, s)
                }
            }

            onPositionChanged: mouse => {
                if (win.mode === "idle")
                    return
                const c = win.clampToLayout(win.toGlobalX(mouse.x), win.toGlobalY(mouse.y))
                switch (win.mode) {
                case "creating":
                    root.ctl.setSelection(Math.min(win.dragGX, c.x), Math.min(win.dragGY, c.y),
                                          Math.abs(c.x - win.dragGX), Math.abs(c.y - win.dragGY))
                    break
                case "moving": {
                    const o = win.origSel
                    root.ctl.setSelection(o.x + (c.x - win.dragGX), o.y + (c.y - win.dragGY), o.w, o.h)
                    break
                }
                case "drawing":
                    annot.updateStroke(c.x, c.y)
                    break
                case "dragStroke":
                    annot.updateMove(c.x, c.y)
                    break
                }
            }

            onReleased: mouse => {
                if (mouse.button === Qt.RightButton)
                    return
                switch (win.mode) {
                case "drawing":
                    annot.endStroke()
                    break
                case "dragStroke":
                    annot.endMove()
                    break
                case "creating":
                    if (root.ctl.selW < win.minSel && root.ctl.selH < win.minSel)
                        root.ctl.setSelection(0, 0, 0, 0) // a click, not a drag
                    break
                }
                win.mode = "idle"
                win.resizeHandle = ""
            }
        }

        // ── Resize handles ───────────────────────────────────────────────────

        Repeater {
            model: win.hasSel && win.dimmable && win.toolKind === ""
                   ? ["tl", "t", "tr", "r", "br", "b", "bl", "l"] : []

            delegate: Rectangle {
                id: handle
                required property string modelData

                readonly property real hx: modelData.indexOf("l") !== -1 ? win.selLX
                                         : modelData.indexOf("r") !== -1 ? win.selLX + win.selLW
                                         : win.selLX + win.selLW / 2
                readonly property real hy: modelData.indexOf("t") !== -1 ? win.selLY
                                         : modelData.indexOf("b") !== -1 ? win.selLY + win.selLH
                                         : win.selLY + win.selLH / 2

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
                    anchors.margins: -6
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

        // ── Toolbar ──────────────────────────────────────────────────────────
        // A Loader so that hiding the selection also destroys the buttons'
        // tooltip Popups, which are parented to the window, not to the bar.

        Loader {
            id: toolbarLoader
            anchors.fill: parent
            active: win.hasSel && win.dimmable && win.ownsSelection && win.mode !== "creating"
            sourceComponent: Toolbar {
                overlay: win
                ctl: root.ctl
                onPickCustomColor: win.openPicker()
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
            id: keyHandler
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (!root.ctl)
                    return
                const ctrl = event.modifiers & Qt.ControlModifier
                const shift = event.modifiers & Qt.ShiftModifier

                switch (event.key) {
                case Qt.Key_Escape:
                    win.peelBack()
                    event.accepted = true
                    return
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.ctl.finishWith("default")
                    event.accepted = true
                    return
                case Qt.Key_Delete:
                case Qt.Key_Backspace:
                    if (root.ctl.selectedId >= 0) {
                        root.ctl.deleteStroke(root.ctl.selectedId)
                        event.accepted = true
                    }
                    return
                }

                if (ctrl) {
                    switch (event.key) {
                    case Qt.Key_C: root.ctl.finishWith("copy"); break
                    case Qt.Key_S: root.ctl.finishWith("save"); break
                    case Qt.Key_Z: shift ? root.ctl.redo() : root.ctl.undo(); break
                    case Qt.Key_Y: root.ctl.redo(); break
                    default: return
                    }
                    event.accepted = true
                    return
                }

                if (event.modifiers & Qt.AltModifier)
                    return
                if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
                    const letter = String.fromCharCode(65 + (event.key - Qt.Key_A))
                    const t = Tools.byKey(letter, root.ctl.enabledTools)
                    if (t) {
                        root.ctl.setTool(t.id)
                        event.accepted = true
                    }
                }
            }
        }

        // ── Export ───────────────────────────────────────────────────────────
        // grabToImage renders exportRoot's subtree at the requested pixel size,
        // so asking for selection × scale samples the frame texture at its
        // full native resolution. Decorations are siblings and stay out.

        function doExport() {
            if (annot.editingText) {
                // Commit, then give the canvas a frame to repaint before grabbing.
                annot.commitTextEdit()
                exportDelay.restart()
                return
            }
            root.ctl.select(-1)
            exportDelay.restart()
        }

        Timer {
            id: exportDelay
            interval: 40
            onTriggered: win.grabNow()
        }

        function grabNow() {
            const s = win.outScale
            // grabToImage's targetSize is in LOGICAL units — Qt multiplies it by
            // the window's devicePixelRatio. outScale and dpr differ under
            // fractional scaling, so both are needed.
            const d = modelData.devicePixelRatio || 1
            const w = Math.max(1, Math.round(root.ctl.selW * s / d))
            const h = Math.max(1, Math.round(root.ctl.selH * s / d))
            const path = "/tmp/dmsplus_" + Date.now() + ".png"

            const ok = annot.exportItem.grabToImage(result => {
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
