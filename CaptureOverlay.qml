import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import "lib/Tools.js" as Tools

// One fullscreen layer-shell window per screen. The toolbar and the
// annotations live in the same scene as the selection rectangle and are
// bound to it, so dragging the selection moves them without any extra code.
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
        // Exclusive so shortcuts reach us; released while the color picker
        // (a separate window) is open.
        WlrLayershell.keyboardFocus: (root.ctl && root.ctl.pickerOpen) ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive

        anchors {
            left: true
            right: true
            top: true
            bottom: true
        }

        // ── Coordinates ──────────────────────────────────────────────────────
        // Global logical -> this screen's local logical is a subtraction.

        readonly property string screenName: modelData.name
        readonly property var info: (root.ctl && root.ctl.screenInfo[screenName]) || null
        readonly property real originX: info ? info.x : modelData.x
        readonly property real originY: info ? info.y : modelData.y
        readonly property real outScale: info ? info.scale : 1
        readonly property string freezeUrl: (root.ctl && root.ctl.freezes[screenName]) ? "file://" + root.ctl.freezes[screenName] : ""
        readonly property bool useScreencopy: root.ctl && root.ctl.backend === "screencopy"

        // dimmable: the grab has returned, so painting can no longer leak into
        // it. The live desktop underneath is the same picture as the frozen
        // frame, so dimming before the frame is decoded looks seamless.
        // frameReady: the frame is on screen. Export waits for it.
        readonly property bool dimmable: root.ctl && !root.ctl.capturing
        readonly property bool frameReady: useScreencopy ? frozen.hasContent : freezeImage.status === Image.Ready

        onFrameReadyChanged: {
            if (frameReady && root.ctl)
                root.ctl.noteFrameReady()
        }

        function toGlobalX(lx) { return lx + originX }
        function toGlobalY(ly) { return ly + originY }
        function toLocalX(gx) { return gx - originX }
        function toLocalY(gy) { return gy - originY }

        // The selection clipped to this screen. Beyond the screen edge there
        // are no pixels, so that part is neither shown nor exported.
        readonly property real selLX: root.ctl ? Math.max(0, toLocalX(root.ctl.selX)) : 0
        readonly property real selLY: root.ctl ? Math.max(0, toLocalY(root.ctl.selY)) : 0
        readonly property real selLW: root.ctl ? Math.min(width, toLocalX(root.ctl.selX) + root.ctl.selW) - selLX : 0
        readonly property real selLH: root.ctl ? Math.min(height, toLocalY(root.ctl.selY) + root.ctl.selH) - selLY : 0
        readonly property bool hasSel: root.ctl ? root.ctl.hasSelection && selLW >= 1 && selLH >= 1 : false

        // The screen showing the largest part of the selection handles keys
        // and export.
        readonly property bool ownsSelection: {
            if (!root.ctl || !root.ctl.hasSelection)
                return true
            const c = root.ctl
            let best = "", bestArea = 0
            for (const name in c.screenInfo) {
                const s = c.screenInfo[name]
                const w = Math.min(s.x + s.width, c.selX + c.selW) - Math.max(s.x, c.selX)
                const h = Math.min(s.y + s.height, c.selY + c.selH) - Math.max(s.y, c.selY)
                if (w > 0 && h > 0 && w * h > bestArea) {
                    bestArea = w * h
                    best = name
                }
            }
            return best === screenName
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

        function beginDrag(gx, gy) {
            dragGX = gx
            dragGY = gy
            origSel = { "x": root.ctl.selX, "y": root.ctl.selY, "w": root.ctl.selW, "h": root.ctl.selH }
        }

        function clampToScreen(gx, gy) {
            return {
                "x": Math.max(originX, Math.min(originX + modelData.width, gx)),
                "y": Math.max(originY, Math.min(originY + modelData.height, gy))
            }
        }

        function insideSel(gx, gy) {
            return hasSel
                && gx >= root.ctl.selX && gx <= root.ctl.selX + root.ctl.selW
                && gy >= root.ctl.selY && gy <= root.ctl.selY + root.ctl.selH
        }

        function applyResize(gx, gy) {
            const o = origSel
            let l = o.x, t = o.y, r = o.x + o.w, b = o.y + o.h
            if (resizeHandle.indexOf("l") !== -1) l = gx
            if (resizeHandle.indexOf("r") !== -1) r = gx
            if (resizeHandle.indexOf("t") !== -1) t = gy
            if (resizeHandle.indexOf("b") !== -1) b = gy
            root.ctl.setSelection(Math.min(l, r), Math.min(t, b), Math.abs(r - l), Math.abs(b - t))
        }

        function clearAnnotations() {
            if (annot.editingText)
                annot.cancelTextEdit()
            root.ctl.clearStrokes()
        }

        // Esc / right click: leave one layer of state at a time.
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

        // ── Color picker ─────────────────────────────────────────────────────
        // DMS's picker lives on the Top layer and gets no keyboard while
        // screenshotActive is set: lift it to Overlay, release our own grab,
        // and undo both when it closes.

        function openPicker() {
            const p = PopoutService.colorPickerModal
            if (!p)
                return
            p.useOverlayLayer = true
            p.selectedColor = root.ctl.strokeColor
            p.pickerTitle = I18n.trFor("screenshotPlus", "Annotation color")
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
            live: false          // a single frame; staying live would capture this overlay
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
            asynchronous: true   // a 4K PNG would block the render thread for ~170ms
        }

        // ── Dimming outside the selection ────────────────────────────────────

        Item {
            anchors.fill: parent
            visible: win.dimmable
            readonly property color dim: Qt.rgba(0, 0, 0, 0.45)   // neutral regardless of theme

            Rectangle { color: parent.dim; x: 0; y: 0; width: parent.width
                        height: win.hasSel ? Math.max(0, win.selLY) : parent.height }
            Rectangle { color: parent.dim; visible: win.hasSel; x: 0; y: win.selLY + win.selLH
                        width: parent.width; height: Math.max(0, parent.height - (win.selLY + win.selLH)) }
            Rectangle { color: parent.dim; visible: win.hasSel; x: 0; y: win.selLY
                        width: Math.max(0, win.selLX); height: win.selLH }
            Rectangle { color: parent.dim; visible: win.hasSel; x: win.selLX + win.selLW; y: win.selLY
                        width: Math.max(0, parent.width - (win.selLX + win.selLW)); height: win.selLH }
        }

        AnnotationLayer {
            id: annot
            overlay: win
            ctl: root.ctl
            frameItem: win.useScreencopy ? frozen : freezeImage
        }

        // ── Selection border and size readout ────────────────────────────────

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
            visible: win.hasSel && win.dimmable
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

        // ── Pointer ──────────────────────────────────────────────────────────

        MouseArea {
            id: mainArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            cursorShape: {
                if (win.mode === "moving")
                    return Qt.ClosedHandCursor
                if (win.mode === "dragStroke")
                    return Qt.SizeAllCursor
                if (win.insideSel(win.toGlobalX(mouseX), win.toGlobalY(mouseY))) {
                    switch (win.toolKind) {
                    case "select": return Qt.ArrowCursor
                    case "text": return Qt.IBeamCursor
                    case "": return Qt.OpenHandCursor
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
                    win.beginDrag(gx, gy)
                    if (inside) {
                        win.mode = "moving"
                    } else {
                        root.ctl.select(-1)
                        root.ctl.setSelection(gx, gy, 0, 0)
                        win.mode = "creating"
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
                const c = win.clampToScreen(win.toGlobalX(mouse.x), win.toGlobalY(mouse.y))
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
                        root.ctl.setSelection(0, 0, 0, 0)   // a click, not a drag
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
                        const c = win.clampToScreen(win.toGlobalX(p.x), win.toGlobalY(p.y))
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
        // A Loader, so hiding the selection also destroys the buttons' tooltip
        // popups, which are parented to the window rather than to the bar.

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

        Text {
            visible: !win.hasSel && win.ownsSelection && win.dimmable
            anchors.centerIn: parent
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeLarge
            text: I18n.trFor("screenshotPlus", "Drag to select an area  ·  Esc to cancel")
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
                    root.ctl.finish("default")
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
                    case Qt.Key_C: root.ctl.finish("copy"); break
                    case Qt.Key_S: root.ctl.finish("save"); break
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
                    const t = Tools.byKey(String.fromCharCode(65 + (event.key - Qt.Key_A)), root.ctl.enabledTools)
                    if (t) {
                        root.ctl.setTool(t.id)
                        event.accepted = true
                    }
                }
            }
        }

        // ── Export ───────────────────────────────────────────────────────────
        // grabToImage renders the export subtree at the requested pixel size,
        // sampling the frame texture at native resolution. Decorations are
        // siblings of that subtree and stay out of the picture.

        function doExport() {
            if (annot.editingText)
                annot.commitTextEdit()
            root.ctl.select(-1)
            exportDelay.restart()   // let the canvases repaint first
        }

        Timer {
            id: exportDelay
            interval: 40
            onTriggered: win.grabNow()
        }

        function grabNow() {
            // targetSize is in logical units and gets multiplied by the
            // window's devicePixelRatio, which differs from the output scale
            // under fractional scaling.
            const d = modelData.devicePixelRatio || 1
            const w = Math.max(1, Math.round(win.selLW * win.outScale / d))
            const h = Math.max(1, Math.round(win.selLH * win.outScale / d))
            const path = "/tmp/screenshot-plus-" + Date.now() + "." + root.ctl.exportFormat

            const ok = annot.exportItem.grabToImage(result => {
                const saved = result.saveToFile(path)
                if (saved) {
                    root.ctl.onExported(path)
                } else {
                    console.warn("screenshotPlus: could not write", path)
                    root.ctl.cancel()
                }
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
