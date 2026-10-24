import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import "lib/Tools.js" as Tools
import "lib/Ocr.js" as Ocr

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

        // dimmable: the frame has been captured, so nothing painted from now
        // on can leak into it. Until then the window stays fully transparent:
        // the compositor renders the screencopy frame at its next redraw, and
        // if something else is animating that redraw comes after our first
        // frame. With the cli backend the grab has to return; the live
        // desktop underneath is the same picture as the frame, so dimming
        // before the PNG is decoded looks seamless.
        // frameReady: the frame is on screen. Export waits for it.
        readonly property bool dimmable: root.ctl && (useScreencopy ? frozen.hasContent : !root.ctl.capturing)
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

        // ── Recognized text ──────────────────────────────────────────────────
        // A double-click on text inside the selection selects the word there,
        // and the OCR button outlines every line found; either recognizes the
        // selection first when needed. The daemon is then in text mode:
        // presses on recognized text select text instead of moving the
        // selection, and copying copies the text. Only the screen that owns
        // the selection does any of this.

        readonly property bool canSelectText: root.ctl !== null && root.ctl.ocrEnabled && win.ownsSelection
                                              && win.frameReady && (win.toolKind === "" || win.toolKind === "select")
        property var textWord: null          // { a, b }: the word or line clicked into; a drag extends from it
        property var pendingText: null       // { mark, x, y }: the double-click (or, with mark, the button) waiting for recognition
        property var lastDoubleClick: null   // { t, x, y }: a press right after it is a triple click

        // The caret position at (gx, gy) on recognized text, or null. With
        // `anywhere` the nearest line counts, for dragging past the text.
        function textCaretAt(gx, gy, anywhere) {
            const lines = root.ctl.ocrLines
            const i = Ocr.lineAt(lines, gx, gy, anywhere ? Infinity : 3)
            return i < 0 ? null : { "line": i, "pos": Ocr.caretIn(lines[i], gx) }
        }

        // `held`: the button is still down, so moving extends from the word.
        function textDoubleClick(gx, gy, held) {
            const c = root.ctl
            if (!c.ocrCurrent()) {
                win.pendingText = { "mark": false, "x": gx, "y": gy }
                if (c.ocrState !== "running")
                    win.startOcr()
                return
            }
            const lines = c.ocrLines
            const i = Ocr.lineAt(lines, gx, gy, 3)
            if (i < 0) {
                win.showHint(lines.length === 0 ? I18n.trFor("screenshotPlus", "No text recognized")
                                                : I18n.trFor("screenshotPlus", "No text here"), gx, gy)
                return
            }
            const w = Ocr.wordAt(lines[i].chars, Ocr.charIn(lines[i], gx))
            const a = { "line": i, "pos": w[0] }
            const b = { "line": i, "pos": w[1] }
            c.setTextSelection(a, b)
            win.textWord = { "a": a, "b": b }
            win.lastDoubleClick = { "t": Date.now(), "x": gx, "y": gy }
            if (held)
                win.mode = "textSelecting"
        }

        // The OCR button and O: outline the text in the selection, or leave
        // text mode when it is already outlined. Drawing tools give way.
        function toggleTextMarks() {
            const c = root.ctl
            if (c.textMarked) {
                c.exitTextMode()
                return
            }
            if (win.toolKind !== "" && win.toolKind !== "select")
                c.setTool("")
            if (c.ocrCurrent()) {
                win.markText()
                return
            }
            win.pendingText = { "mark": true, "x": win.toGlobalX(win.selLX), "y": win.toGlobalY(win.selLY) }
            if (c.ocrState !== "running")
                win.startOcr()
        }

        function markText() {
            if (root.ctl.ocrLines.length > 0)
                root.ctl.markText()
            else
                win.showHint(I18n.trFor("screenshotPlus", "No text recognized"), win.toGlobalX(win.selLX), win.toGlobalY(win.selLY))
        }

        // A press on recognized text in text mode: the caret goes there,
        // Shift extends, and a press right after a double-click takes the line.
        function pressText(caret, gx, gy, extend) {
            const c = root.ctl
            const d = win.lastDoubleClick
            win.lastDoubleClick = null
            win.textWord = null
            if (d && Date.now() - d.t < Qt.styleHints.mouseDoubleClickInterval
                    && Math.abs(gx - d.x) < 4 && Math.abs(gy - d.y) < 4) {
                const a = { "line": caret.line, "pos": 0 }
                const b = { "line": caret.line, "pos": c.ocrLines[caret.line].chars.length }
                c.setTextSelection(a, b)
                win.textWord = { "a": a, "b": b }
            } else {
                c.setTextSelection(extend && c.textAnchor ? c.textAnchor : caret, caret)
            }
            win.mode = "textSelecting"
        }

        function dragText(gx, gy) {
            const c = root.ctl
            const caret = win.textCaretAt(gx, gy, true)
            const w = win.textWord
            if (!caret)
                return
            if (!w)
                c.setTextSelection(c.textAnchor, caret)
            else if (Ocr.comparePos(caret, w.a) < 0)
                c.setTextSelection(w.b, caret)
            else if (Ocr.comparePos(caret, w.b) > 0)
                c.setTextSelection(w.a, caret)
            else
                c.setTextSelection(w.a, w.b)
        }

        // Copies the selected text; the overlay stays, a hint below the text says so.
        function copyText() {
            const n = root.ctl.copySelectedText()
            const f = root.ctl.textFocus
            const l = f ? root.ctl.ocrLines[f.line] : null
            win.showHint(n > 0 ? I18n.trFor("screenshotPlus", "Copied %1 characters").arg(n)
                               : I18n.trFor("screenshotPlus", "No text selected"),
                         l ? l.xs[f.pos] : win.toGlobalX(win.selLX),
                         l ? l.y + l.h : win.toGlobalY(win.selLY))
        }

        // The selection's part of the frame, without annotations, at native
        // resolution, written for the daemon to recognize. oar reads PPM,
        // which unlike PNG costs the GUI thread next to nothing to write.
        function startOcr() {
            const c = root.ctl
            const d = modelData.devicePixelRatio || 1
            const w = Math.max(1, Math.round(win.selLW * win.outScale / d))
            const h = Math.max(1, Math.round(win.selLH * win.outScale / d))
            const path = "/tmp/screenshot-plus-ocr-" + Date.now() + ".ppm"
            const map = { "x": win.toGlobalX(win.selLX), "y": win.toGlobalY(win.selLY),
                          "sx": w * d / win.selLW, "sy": h * d / win.selLH }
            const token = c.beginOcr()
            const ok = annot.frameCopyItem.grabToImage(result => {
                if (result.saveToFile(path))
                    c.recognize(token, path, map)
                else
                    c.failOcr(token, I18n.trFor("screenshotPlus", "could not write %1").arg(path))
            }, Qt.size(w, h))
            if (!ok)
                c.failOcr(token, I18n.trFor("screenshotPlus", "could not grab the selection"))
        }

        Connections {
            target: root.ctl
            function onOcrFinished(error) {
                const p = win.pendingText
                win.pendingText = null
                if (!p || !win.canSelectText)   // e.g. a drawing tool was picked meanwhile
                    return
                if (error !== "")
                    win.showHint(I18n.trFor("screenshotPlus", "Text recognition failed: %1").arg(error), p.x, p.y)
                else if (p.mark)
                    win.markText()
                else
                    win.textDoubleClick(p.x, p.y, false)
            }
        }

        // Esc / right click: leave one layer of state at a time.
        function peelBack() {
            if (root.ctl.ocrState === "running")
                root.ctl.cancelOcr()
            else if (root.ctl.textMode)
                root.ctl.exitTextMode()
            else if (annot.editingText)
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

        // The lines found, outlined after the OCR button, and under them the
        // selected text, highlighted like a text box's selection. Neither is
        // exported.
        Repeater {
            model: root.ctl && root.ctl.textMarked && win.ownsSelection ? root.ctl.ocrLines : []
            delegate: Rectangle {
                required property var modelData
                readonly property int pad: 2
                x: win.toLocalX(modelData.x) - pad
                y: win.toLocalY(modelData.y) - pad
                width: modelData.w + pad * 2
                height: modelData.h + pad * 2
                radius: 3
                color: Theme.withAlpha(Theme.primary, 0.12)
                border.color: Theme.withAlpha(Theme.primary, 0.7)
                border.width: 1
            }
        }

        Repeater {
            model: root.ctl && root.ctl.hasSelectedText && win.ownsSelection
                   ? Ocr.rectsBetween(root.ctl.ocrLines, root.ctl.textAnchor, root.ctl.textFocus) : []
            delegate: Rectangle {
                required property var modelData
                x: win.toLocalX(modelData.x)
                y: win.toLocalY(modelData.y)
                width: modelData.w
                height: modelData.h
                radius: 2
                color: Theme.withAlpha(Theme.primary, 0.35)
            }
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
            onEntered: if (root.ctl) root.ctl.hoverScreen = win.screenName
            cursorShape: {
                if (win.mode === "textSelecting")
                    return Qt.IBeamCursor
                if (win.mode === "moving")
                    return Qt.ClosedHandCursor
                if (win.mode === "dragStroke")
                    return Qt.SizeAllCursor
                const gx = win.toGlobalX(mouseX)
                const gy = win.toGlobalY(mouseY)
                if (win.insideSel(gx, gy)) {
                    if (root.ctl.textMode && win.textCaretAt(gx, gy, false))
                        return Qt.IBeamCursor
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

                // In text mode a press on recognized text selects text; any
                // other press leaves text mode and does what it always did.
                if (root.ctl.textMode) {
                    const caret = inside ? win.textCaretAt(gx, gy, false) : null
                    if (caret) {
                        win.pressText(caret, gx, gy, mouse.modifiers & Qt.ShiftModifier)
                        return
                    }
                    root.ctl.exitTextMode()
                }

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

            // Arrives on the second press, after onPressed has handled it.
            onDoubleClicked: mouse => {
                if (mouse.button !== Qt.LeftButton)
                    return
                const gx = win.toGlobalX(mouse.x)
                const gy = win.toGlobalY(mouse.y)
                if (win.toolKind === "select") {
                    const s = annot.hitAt(gx, gy)
                    if (s) {
                        if (s.tool === "text") {
                            if (win.mode === "dragStroke")
                                annot.endMove()
                            win.mode = "idle"
                            annot.beginTextEdit(0, 0, s)
                        }
                        return
                    }
                }
                if (win.canSelectText && win.insideSel(gx, gy)) {
                    if (win.mode === "moving")
                        win.mode = "idle"   // the press began moving the selection
                    win.textDoubleClick(gx, gy, true)
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
                case "textSelecting":
                    win.dragText(c.x, c.y)
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

        Column {
            visible: !win.hasSel && win.ownsSelection && win.dimmable
            anchors.centerIn: parent
            spacing: Theme.spacingS

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                text: I18n.trFor("screenshotPlus", "Drag to select an area  ·  Esc to cancel")
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.6)
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                color: Theme.surfaceText
                opacity: 0.8
                font.pixelSize: Theme.fontSizeMedium
                text: root.ctl && root.ctl.hasRegionHistory
                      ? I18n.trFor("screenshotPlus", "F  whole screen  ·  < >  previous regions")
                      : I18n.trFor("screenshotPlus", "F  whole screen")
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.6)
            }
        }

        // ── Text hint ────────────────────────────────────────────────────────
        // Short feedback where the text is: recognizing, copied, nothing there.

        property string hintText: ""
        property real hintGX: 0
        property real hintGY: 0
        readonly property bool recognizing: root.ctl !== null && root.ctl.ocrState === "running"
                                            && win.pendingText !== null

        function showHint(text, gx, gy) {
            win.hintText = text
            win.hintGX = gx
            win.hintGY = gy
            hintTimer.restart()
        }

        Timer {
            id: hintTimer
            interval: 1800
            onTriggered: win.hintText = ""
        }

        Rectangle {
            readonly property string message: win.recognizing ? I18n.trFor("screenshotPlus", "Recognizing text…") : win.hintText
            readonly property real gx: win.recognizing ? win.pendingText.x : win.hintGX
            readonly property real gy: win.recognizing ? win.pendingText.y : win.hintGY
            visible: message !== "" && win.ownsSelection && win.hasSel && win.dimmable
            color: Theme.withAlpha(Theme.surfaceContainer, 0.9)
            radius: Theme.cornerRadiusSmall
            border.color: Theme.withAlpha(Theme.outline, 0.3)
            border.width: 1
            width: hintLabel.implicitWidth + Theme.spacingM
            height: hintLabel.implicitHeight + Theme.spacingXS
            x: Math.max(0, Math.min(win.width - width, win.toLocalX(gx)))
            y: Math.max(0, Math.min(win.height - height, win.toLocalY(gy) + Theme.spacingS))

            Text {
                id: hintLabel
                anchors.centerIn: parent
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                text: parent.message
            }
        }

        onVisibleChanged: {
            if (visible)
                return
            win.hintText = ""
            win.pendingText = null
            win.textWord = null
            win.lastDoubleClick = null
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
                case Qt.Key_Space:
                    if (root.ctl.textMode)
                        win.copyText()
                    else
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
                    case Qt.Key_C:
                        if (root.ctl.textMode)
                            win.copyText()
                        else
                            root.ctl.finish("copy")
                        break
                    case Qt.Key_A:
                        if (!root.ctl.textMode)
                            return
                        root.ctl.selectAllText()
                        break
                    case Qt.Key_S: root.ctl.finish("save"); break
                    case Qt.Key_P: root.ctl.finish("pin"); break
                    case Qt.Key_Z: shift ? root.ctl.redo() : root.ctl.undo(); break
                    case Qt.Key_Y: root.ctl.redo(); break
                    default: return
                    }
                    event.accepted = true
                    return
                }

                if (event.modifiers & Qt.AltModifier)
                    return

                switch (event.key) {
                case Qt.Key_F:
                    root.ctl.selectScreen(root.ctl.hoverScreen || win.screenName)
                    event.accepted = true
                    return
                case Qt.Key_O:
                    if (root.ctl.ocrEnabled && win.hasSel && win.ownsSelection && win.frameReady) {
                        win.toggleTextMarks()
                        event.accepted = true
                    }
                    return
                case Qt.Key_Less:          // `,` too, so no Shift is needed on a US layout
                case Qt.Key_Comma:
                    root.ctl.restoreRegion(1)
                    event.accepted = true
                    return
                case Qt.Key_Greater:
                case Qt.Key_Period:
                    root.ctl.restoreRegion(-1)
                    event.accepted = true
                    return
                }

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
            // Read now: the selection is gone by the time the grab returns.
            const geom = { "screen": win.screenName, "x": win.selLX, "y": win.selLY, "w": win.selLW, "h": win.selLH }

            const ok = annot.exportItem.grabToImage(result => {
                const saved = result.saveToFile(path)
                if (saved) {
                    root.ctl.onExported(path, geom)
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
