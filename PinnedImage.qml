import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets

// One pinned capture: the exported picture kept on screen where the
// selection was, above normal windows, until it is closed.
//
// The window covers the whole screen but is transparent and only the
// picture (and the action bar while it is shown) takes input, so dragging
// moves an Item inside a window that never moves itself. Keyboard focus is
// on demand: a click on the picture brings the keys here.
//
//   drag                      move
//   wheel, + / -, 0           scale around the pointer, back to 1:1
//   Ctrl + wheel              opacity
//   Enter / Space / Ctrl+C    copy to clipboard
//   S / Ctrl+S                save to file
//   right click / Tab         copy, save and close buttons
//   Esc / Q / double click    close (Esc hides the buttons first)
//   middle click              close
PanelWindow {
    id: win

    required property var modelData     // { id, screen, x, y, w, h, src }, see the daemon
    property var ctl: null

    readonly property var pin: modelData

    screen: {
        const list = Quickshell.screens
        for (let i = 0; i < list.length; i++)
            if (list[i].name === win.pin.screen)
                return list[i]
        return null
    }
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "dms:screenshot-plus-pin"
    WlrLayershell.layer: WlrLayer.Top                      // under the capture overlay, so it is in the next frame
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    // Everything outside the picture and the bar passes through to what is
    // underneath. Hidden bar: an empty region.
    mask: Region {
        item: frame
        Region {
            x: bar.visible ? bar.x : 0
            y: bar.visible ? bar.y : 0
            width: bar.visible ? bar.width : 0
            height: bar.visible ? bar.height : 0
        }
    }

    // ── Geometry ─────────────────────────────────────────────────────────────

    property real posX: pin.x
    property real posY: pin.y
    property real zoom: 1
    property real picOpacity: 1
    readonly property int shownW: Math.max(1, Math.round(pin.w * zoom))
    readonly property int shownH: Math.max(1, Math.round(pin.h * zoom))
    readonly property int keepVisible: 32          // px of the picture that must stay on screen
    readonly property real minZoom: keepVisible / Math.max(pin.w, pin.h)
    readonly property real maxZoom: 4

    function moveTo(x, y) {
        posX = Math.round(Math.max(keepVisible - shownW, Math.min(width - keepVisible, x)))
        posY = Math.round(Math.max(keepVisible - shownH, Math.min(height - keepVisible, y)))
    }

    // Scale by `f` keeping the window point (wx, wy) over the same picture point.
    function zoomBy(f, wx, wy) {
        const z = Math.max(minZoom, Math.min(maxZoom, zoom * f))
        if (z === zoom)
            return
        const k = z / zoom
        zoom = z
        moveTo(wx - (wx - posX) * k, wy - (wy - posY) * k)
    }

    function resetZoom() {
        const cx = posX + shownW / 2
        const cy = posY + shownH / 2
        zoom = 1
        picOpacity = 1
        moveTo(cx - shownW / 2, cy - shownH / 2)
    }

    function close() {
        if (ctl)
            ctl.unpin(pin.id)
    }

    // ── Picture ──────────────────────────────────────────────────────────────
    // A highlight border around the picture, brighter on the pin that has
    // the keyboard. It sits outside the picture, which stays where the
    // capture was.

    Rectangle {
        id: frame
        readonly property int bw: 2
        x: win.posX - bw
        y: win.posY - bw
        width: win.shownW + bw * 2
        height: win.shownH + bw * 2
        opacity: win.picOpacity
        color: "transparent"
        border.width: bw
        border.color: keys.activeFocus ? Theme.primary : Theme.withAlpha(Theme.primary, 0.5)

        Image {
            id: picture
            anchors.fill: parent
            anchors.margins: frame.bw
            source: "file://" + win.pin.src
            // Loaded here and now: finalize.sh deletes the file as soon as it has
            // converted it, which may be before the next frame.
            asynchronous: false
            fillMode: Image.Stretch
            smooth: true
            mipmap: true

            onStatusChanged: {
                if (status === Image.Error)
                    console.warn("screenshotPlus: pin could not load", win.pin.src)
            }
        }

        MouseArea {
            id: area
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            hoverEnabled: true
            cursorShape: dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

            property bool dragging: false
            property real pressWX: 0
            property real pressWY: 0
            property real startX: 0
            property real startY: 0

            onPressed: mouse => {
                keys.forceActiveFocus()
                if (mouse.button !== Qt.LeftButton)
                    return
                const p = mapToItem(null, mouse.x, mouse.y)
                pressWX = p.x
                pressWY = p.y
                startX = win.posX
                startY = win.posY
                dragging = true
            }
            onPositionChanged: mouse => {
                if (!dragging)
                    return
                const p = mapToItem(null, mouse.x, mouse.y)
                win.moveTo(startX + p.x - pressWX, startY + p.y - pressWY)
            }
            onReleased: dragging = false
            onCanceled: dragging = false

            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    win.showBar(p.x, p.y)
                } else if (mouse.button === Qt.MiddleButton) {
                    win.close()
                }
            }
            onDoubleClicked: mouse => {
                if (mouse.button === Qt.LeftButton)
                    win.close()
            }

            onWheel: wheel => {
                const steps = (wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x) / 120
                if (steps === 0)
                    return
                if (wheel.modifiers & Qt.ControlModifier) {
                    win.picOpacity = Math.max(0.2, Math.min(1, win.picOpacity + steps * 0.1))
                } else {
                    const p = mapToItem(null, wheel.x, wheel.y)
                    win.zoomBy(Math.pow(1.1, steps), p.x, p.y)
                }
                wheel.accepted = true
            }
        }
    }

    // ── Action bar ───────────────────────────────────────────────────────────
    // Shown on demand only: a bar that appeared on hover would end up in the
    // frame of the next capture whenever the pointer rested on a pin.

    property bool barShown: false

    function showBar(wx, wy) {
        bar.x = Math.round(Math.max(0, Math.min(width - bar.width, wx)))
        bar.y = Math.round(Math.max(0, Math.min(height - bar.height, wy)))
        barShown = true
    }

    function toggleBar() {
        if (barShown)
            barShown = false
        else
            showBar(posX + Theme.spacingS, posY + Theme.spacingS)
    }

    // The bar goes away once the pointer has left both it and the picture.
    Timer {
        interval: 600
        running: win.barShown && !area.containsMouse && !barHover.containsMouse
        onTriggered: win.barShown = false
    }

    component BarButton: DankActionButton {
        buttonSize: 32
        iconSize: 20
        iconColor: Theme.surfaceText
        tooltipSide: "bottom"
    }

    Rectangle {
        id: bar
        visible: win.barShown
        width: row.implicitWidth + Theme.spacingM * 2
        height: row.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.color: Theme.withAlpha(Theme.outline, 0.2)
        border.width: 1

        MouseArea {
            id: barHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 2

            BarButton {
                iconName: "content_copy"
                iconColor: Theme.success
                tooltipText: I18n.trFor("screenshotPlus", "Copy to clipboard (Enter / Space)")
                onClicked: { win.barShown = false; win.ctl.exportPin(win.pin.id, "copy") }
            }
            BarButton {
                iconName: "save"
                tooltipText: I18n.trFor("screenshotPlus", "Save to file (Ctrl+S)")
                onClicked: { win.barShown = false; win.ctl.exportPin(win.pin.id, "save") }
            }
            BarButton {
                iconName: "close"
                iconColor: Theme.error
                tooltipText: I18n.trFor("screenshotPlus", "Close (Esc)")
                onClicked: win.close()
            }
        }
    }

    // ── Keyboard ─────────────────────────────────────────────────────────────

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            if (!win.ctl)
                return
            const ctrl = event.modifiers & Qt.ControlModifier
            event.accepted = true
            switch (event.key) {
            case Qt.Key_Escape:
                if (win.barShown)
                    win.barShown = false
                else
                    win.close()
                return
            case Qt.Key_Q:
                win.close()
                return
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space:
                win.ctl.exportPin(win.pin.id, "copy")
                return
            case Qt.Key_C:
                if (ctrl)
                    win.ctl.exportPin(win.pin.id, "copy")
                return
            case Qt.Key_S:
                win.ctl.exportPin(win.pin.id, "save")
                return
            case Qt.Key_Tab:
                win.toggleBar()
                return
            case Qt.Key_Plus:
            case Qt.Key_Equal:
                win.zoomBy(1.1, win.posX + win.shownW / 2, win.posY + win.shownH / 2)
                return
            case Qt.Key_Minus:
                win.zoomBy(1 / 1.1, win.posX + win.shownW / 2, win.posY + win.shownH / 2)
                return
            case Qt.Key_0:
                win.resetZoom()
                return
            }
            event.accepted = false
        }
    }
}
