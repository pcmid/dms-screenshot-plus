import QtQuick
import qs.Common
import qs.Widgets
import "lib/Tools.js" as Tools

// The toolbar that follows the selection, plus the colour / size panel.
// Fills the window; the bar and the panel position themselves inside it, so
// the parent can simply Loader { anchors.fill } this and forget about it.
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
    // The tool whose size the panel edits: the active one, or pen when none.
    readonly property string sizeTool: {
        const t = ctl ? Tools.byId(ctl.activeTool) : null
        return t && t.widths ? t.id : "pen"
    }
    readonly property var visibleTools: ctl ? Tools.enabled(ctl.enabledTools) : []
    // True when the bar sits below the selection (the panel then goes below the bar).
    readonly property bool barBelow: overlay.selLY + overlay.selLH + gap + bar.height < overlay.height

    anchors.fill: parent

    function closePanel() { panelOpen = false }


    Rectangle {
        id: bar

        width: row.implicitWidth + Theme.spacingM * 2
        height: row.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.color: Theme.withAlpha(Theme.outline, 0.2)
        border.width: 1

        // Right-aligned with the selection, clamped to the screen.
        x: Math.max(toolbar.pad, Math.min(overlay.width - width - toolbar.pad,
                                          overlay.selLX + overlay.selLW - width))
        // Below the selection; flip above when there's no room; last resort
        // is tucking it inside the selection's bottom edge.
        y: toolbar.barBelow
           ? overlay.selLY + overlay.selLH + toolbar.gap
           : ((overlay.selLY - toolbar.gap - height > 0)
              ? overlay.selLY - toolbar.gap - height
              : Math.max(toolbar.pad, overlay.selLY + overlay.selLH - height - toolbar.gap))

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 2

            // Tools
            Repeater {
                model: toolbar.visibleTools
                delegate: DankActionButton {
                    required property var modelData
                    readonly property bool active: ctl && ctl.activeTool === modelData.id
                    iconName: modelData.icon
                    buttonSize: 32
                    iconSize: 20
                    tooltipText: modelData.label + " (" + modelData.key + ")"
                    tooltipSide: toolbar.barBelow ? "bottom" : "top"
                    backgroundColor: active ? Theme.withAlpha(Theme.primary, 0.25) : "transparent"
                    iconColor: active ? Theme.primary : Theme.surfaceText
                    onClicked: {
                        toolbar.closePanel()
                        ctl.setTool(modelData.id)
                    }
                }
            }

            Item { width: 6; height: 1 }
            Rectangle { width: 1; height: 20; anchors.verticalCenter: parent.verticalCenter; color: Theme.withAlpha(Theme.outline, 0.3) }
            Item { width: 6; height: 1 }

            // Style: current colour + size
            DankActionButton {
                iconName: "palette"
                buttonSize: 32
                iconSize: 20
                tooltipText: "颜色 / 粗细"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                backgroundColor: toolbar.panelOpen ? Theme.withAlpha(Theme.primary, 0.25) : "transparent"
                iconColor: ctl ? ctl.strokeColor : Theme.surfaceText
                onClicked: toolbar.panelOpen = !toolbar.panelOpen
            }

            Item { width: 6; height: 1 }
            Rectangle { width: 1; height: 20; anchors.verticalCenter: parent.verticalCenter; color: Theme.withAlpha(Theme.outline, 0.3) }
            Item { width: 6; height: 1 }

            DankActionButton {
                iconName: "undo"
                buttonSize: 32
                iconSize: 20
                enabled: ctl && ctl.canUndo
                iconColor: enabled ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                tooltipText: "撤销 (Ctrl+Z)"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                onClicked: ctl.undo()
            }
            DankActionButton {
                iconName: "redo"
                buttonSize: 32
                iconSize: 20
                enabled: ctl && ctl.canRedo
                iconColor: enabled ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                tooltipText: "重做 (Ctrl+Shift+Z)"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                onClicked: ctl.redo()
            }

            Item { width: 6; height: 1 }
            Rectangle { width: 1; height: 20; anchors.verticalCenter: parent.verticalCenter; color: Theme.withAlpha(Theme.outline, 0.3) }
            Item { width: 6; height: 1 }

            DankActionButton {
                iconName: "save"
                buttonSize: 32
                iconSize: 20
                iconColor: Theme.surfaceText
                tooltipText: "保存到文件 (Ctrl+S)"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                onClicked: ctl.finishWith("save")
            }
            DankActionButton {
                iconName: "content_copy"
                buttonSize: 32
                iconSize: 20
                iconColor: Theme.success
                tooltipText: "复制到剪贴板 (Enter)"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                onClicked: ctl.finishWith("copy")
            }
            DankActionButton {
                iconName: "close"
                buttonSize: 32
                iconSize: 20
                iconColor: Theme.error
                tooltipText: "取消 (Esc)"
                tooltipSide: toolbar.barBelow ? "bottom" : "top"
                onClicked: ctl.cancel()
            }
        }
    }

    // ── Colour / size panel ──────────────────────────────────────────────────

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
        y: toolbar.barBelow ? bar.y + bar.height + toolbar.gap : bar.y - height - toolbar.gap

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
                    tooltipText: "自定义颜色"
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
                    text: (Tools.byId(toolbar.sizeTool) || {}).label || ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
