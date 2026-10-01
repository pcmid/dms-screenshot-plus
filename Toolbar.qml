import QtQuick
import qs.Common
import qs.Widgets
import "lib/Tools.js" as Tools

// The toolbar that follows the selection, plus the color / size panel.
// Fills the window; the bar and the panel position themselves inside it.
Item {
    id: toolbar

    property var overlay: null
    property var ctl: null
    property bool panelOpen: false

    signal pickCustomColor()

    readonly property int gap: Theme.spacingS
    readonly property int pad: Theme.spacingS
    readonly property var presetColors: ["#ff5252", "#ff9800", "#ffeb3b", "#4caf50",
                                         "#2196f3", "#9c27b0", "#ffffff", "#000000"]
    readonly property var visibleTools: ctl ? Tools.enabled(ctl.enabledTools) : []
    // The tool whose size the panel edits: the active one, or pen when none.
    readonly property string sizeTool: {
        const t = ctl ? Tools.byId(ctl.activeTool) : null
        return t && t.widths ? t.id : "pen"
    }
    // The bar sits below the selection when there is room, else above it.
    readonly property bool barBelow: overlay.selLY + overlay.selLH + gap + bar.height < overlay.height

    // Dragged by its handle, the bar keeps that position instead of following
    // the selection. The toolbar is created anew for a new selection, which
    // puts the bar back next to it.
    property bool placed: false
    property real placedX: 0
    property real placedY: 0

    // Where the panel and the tooltips open: away from the selection, or
    // wherever there is room once the bar has been placed by hand.
    readonly property bool openDown: placed ? bar.y + bar.height + gap + panel.height < overlay.height : barBelow
    readonly property string tooltipSide: openDown ? "bottom" : "top"

    anchors.fill: parent

    function closePanel() { panelOpen = false }

    component BarButton: DankActionButton {
        buttonSize: 32
        iconSize: 20
        iconColor: Theme.surfaceText
        tooltipSide: toolbar.tooltipSide
    }

    component Divider: Item {
        width: 13
        height: 32   // as tall as the buttons, so the line sits on their center
        Rectangle { anchors.centerIn: parent; width: 1; height: 20; color: Theme.withAlpha(Theme.outline, 0.3) }
    }

    // Swallows clicks on padding and dividers, which would otherwise reach
    // the overlay underneath and start a new selection.
    component ClickShield: MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
    }

    Rectangle {
        id: bar

        width: row.implicitWidth + Theme.spacingM * 2
        height: row.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.color: Theme.withAlpha(Theme.outline, 0.2)
        border.width: 1

        ClickShield {}

        // Right-aligned with the selection, clamped to the screen; or where
        // it was dragged to.
        x: toolbar.placed ? Math.max(0, Math.min(overlay.width - width, toolbar.placedX))
           : Math.max(toolbar.pad, Math.min(overlay.width - width - toolbar.pad,
                                            overlay.selLX + overlay.selLW - width))
        y: toolbar.placed ? Math.max(0, Math.min(overlay.height - height, toolbar.placedY))
           : toolbar.barBelow ? overlay.selLY + overlay.selLH + toolbar.gap
           : overlay.selLY - toolbar.gap - height > 0 ? overlay.selLY - toolbar.gap - height
           : Math.max(toolbar.pad, overlay.selLY + overlay.selLH - height - toolbar.gap)

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 2

            // Drag handle, see `placed`.
            Item {
                width: 18
                height: 32

                DankIcon {
                    anchors.centerIn: parent
                    name: "drag_indicator"
                    size: 20
                    color: Theme.withAlpha(Theme.surfaceText, handleArea.pressed ? 1 : 0.6)
                }

                MouseArea {
                    id: handleArea
                    anchors.fill: parent
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                    // Pointer offset inside the bar at the press, so the bar
                    // does not jump under the pointer.
                    property real grabDX: 0
                    property real grabDY: 0

                    onPressed: mouse => {
                        const p = mapToItem(toolbar, mouse.x, mouse.y)
                        grabDX = p.x - bar.x
                        grabDY = p.y - bar.y
                    }
                    onPositionChanged: mouse => {
                        if (!pressed)
                            return
                        const p = mapToItem(toolbar, mouse.x, mouse.y)
                        toolbar.placedX = p.x - grabDX
                        toolbar.placedY = p.y - grabDY
                        toolbar.placed = true
                    }
                }
            }

            Repeater {
                model: toolbar.visibleTools
                delegate: BarButton {
                    required property var modelData
                    readonly property bool active: ctl && ctl.activeTool === modelData.id
                    iconName: modelData.icon
                    tooltipText: I18n.trFor("screenshotPlus", modelData.label) + " (" + modelData.key + ")"
                    backgroundColor: active ? Theme.withAlpha(Theme.primary, 0.25) : "transparent"
                    iconColor: active ? Theme.primary : Theme.surfaceText
                    onClicked: {
                        toolbar.closePanel()
                        ctl.setTool(modelData.id)
                    }
                }
            }

            Divider {}

            BarButton {
                iconName: "palette"
                tooltipText: I18n.trFor("screenshotPlus", "Color / size")
                backgroundColor: toolbar.panelOpen ? Theme.withAlpha(Theme.primary, 0.25) : "transparent"
                iconColor: ctl ? ctl.strokeColor : Theme.surfaceText
                onClicked: toolbar.panelOpen = !toolbar.panelOpen
            }

            Divider {}

            BarButton {
                iconName: "undo"
                enabled: ctl && ctl.canUndo
                iconColor: enabled ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                tooltipText: I18n.trFor("screenshotPlus", "Undo (Ctrl+Z)")
                onClicked: ctl.undo()
            }
            BarButton {
                iconName: "redo"
                enabled: ctl && ctl.canRedo
                iconColor: enabled ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                tooltipText: I18n.trFor("screenshotPlus", "Redo (Ctrl+Shift+Z)")
                onClicked: ctl.redo()
            }
            BarButton {
                iconName: "delete_sweep"
                enabled: ctl && ctl.strokes.length > 0
                iconColor: enabled ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                tooltipText: I18n.trFor("screenshotPlus", "Clear all annotations")
                onClicked: overlay.clearAnnotations()
            }

            Divider {}

            BarButton {
                iconName: "push_pin"
                tooltipText: I18n.trFor("screenshotPlus", "Pin to screen (Ctrl+P)")
                onClicked: ctl.finish("pin")
            }
            BarButton {
                iconName: "save"
                tooltipText: I18n.trFor("screenshotPlus", "Save to file (Ctrl+S)")
                onClicked: ctl.finish("save")
            }
            BarButton {
                iconName: "content_copy"
                iconColor: Theme.success
                tooltipText: I18n.trFor("screenshotPlus", "Copy to clipboard (Enter / Space)")
                onClicked: ctl.finish("copy")
            }
            BarButton {
                iconName: "close"
                iconColor: Theme.error
                tooltipText: I18n.trFor("screenshotPlus", "Cancel (Esc)")
                onClicked: ctl.cancel()
            }
        }
    }

    // ── Color / size panel ───────────────────────────────────────────────────

    Rectangle {
        id: panel
        visible: toolbar.panelOpen
        width: panelCol.implicitWidth + Theme.spacingM * 2
        height: panelCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.color: Theme.withAlpha(Theme.outline, 0.2)
        border.width: 1
        x: Math.max(toolbar.pad, Math.min(overlay.width - width - toolbar.pad, bar.x + bar.width - width))
        y: toolbar.openDown ? bar.y + bar.height + toolbar.gap : bar.y - height - toolbar.gap

        ClickShield {}

        Column {
            id: panelCol
            anchors.centerIn: parent
            spacing: Theme.spacingS

            Row {
                spacing: Theme.spacingXS

                Repeater {
                    model: toolbar.presetColors
                    delegate: Rectangle {
                        required property string modelData
                        readonly property bool current: ctl && String(ctl.strokeColor).toLowerCase() === modelData.toLowerCase()
                        width: 26
                        height: 26
                        radius: 13
                        color: modelData
                        border.color: current ? Theme.primary : Theme.withAlpha(Theme.outline, 0.5)
                        border.width: current ? 3 : 1

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ctl.strokeColor = modelData
                        }
                    }
                }

                DankActionButton {
                    iconName: "colorize"
                    buttonSize: 26
                    iconSize: 16
                    iconColor: Theme.surfaceText
                    tooltipText: I18n.trFor("screenshotPlus", "Custom color")
                    onClicked: toolbar.pickCustomColor()
                }
            }

            Row {
                spacing: Theme.spacingXS

                Repeater {
                    model: Tools.PRESETS
                    delegate: Rectangle {
                        required property string modelData
                        readonly property real px: Tools.widthFor(toolbar.sizeTool, modelData)
                        readonly property bool current: ctl && ctl.toolWidths[toolbar.sizeTool] === px
                        width: 44
                        height: 26
                        radius: Theme.cornerRadiusSmall
                        color: current ? Theme.withAlpha(Theme.primary, 0.25)
                                       : (sizeArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.1) : "transparent")
                        border.color: Theme.withAlpha(Theme.outline, 0.3)
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: modelData + " " + px
                            font.pixelSize: Theme.fontSizeSmall
                            color: current ? Theme.primary : Theme.surfaceText
                        }

                        MouseArea {
                            id: sizeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ctl.setToolWidth(toolbar.sizeTool, px)
                        }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: Theme.spacingXS
                    text: I18n.trFor("screenshotPlus", (Tools.byId(toolbar.sizeTool) || {}).label || "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
