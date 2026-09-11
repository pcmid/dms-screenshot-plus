import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "lib/Config.js" as Config
import "lib/Tools.js" as Tools

// DMS Settings -> Plugins -> Screenshot+. Defaults come from lib/Config.js.
PluginSettings {
    id: root
    pluginId: "screenshotPlus"

    readonly property var toolHints: ({
        "select": "Click an annotation to select it, drag to move it, Delete to remove it, double-click text to edit it",
        "highlighter": "Wide translucent stroke",
        "text": "Enter commits, Shift+Enter inserts a line break, Esc cancels",
        "number": "Click to place an incrementing marker; removing one renumbers the rest"
    })

    component SectionTitle: StyledText {
        width: parent.width
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    component SectionNote: StyledText {
        width: parent.width
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SectionTitle { text: "Toolbar" }
    SectionNote { text: "Disabled tools are hidden from the toolbar and lose their shortcut." }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Repeater {
            model: Tools.TOOLS
            delegate: ToggleSetting {
                required property var modelData
                settingKey: Config.toolEnabledKey(modelData.id)
                label: modelData.label + " (" + modelData.key + ")"
                description: root.toolHints[modelData.id] || ""
                defaultValue: true
            }
        }
    }

    SectionTitle { text: "Default style"; topPadding: Theme.spacingM }

    ColorSetting {
        settingKey: "defaultColor"
        label: "Color"
        description: "Annotation color at the start of every capture; the toolbar can change it for the session"
        defaultValue: Config.DEFAULTS.defaultColor
    }

    SelectionSetting {
        settingKey: "defaultWidthPreset"
        label: "Size"
        description: "Each tool maps S / M / L / XL to its own values: line width, font size, mosaic block size, marker radius"
        options: [
            { "label": "S", "value": "S" },
            { "label": "M", "value": "M" },
            { "label": "L", "value": "L" },
            { "label": "XL", "value": "XL" }
        ]
        defaultValue: Config.DEFAULTS.defaultWidthPreset
    }

    SectionTitle { text: "Output"; topPadding: Theme.spacingM }

    ToggleSetting {
        settingKey: "copyToClipboard"
        label: "Copy to clipboard"
        description: "On Enter. The toolbar's copy button always copies"
        defaultValue: Config.DEFAULTS.copyToClipboard
    }

    ToggleSetting {
        settingKey: "saveToFile"
        label: "Save to file"
        description: "On Enter. The toolbar's save button (Ctrl+S) always saves"
        defaultValue: Config.DEFAULTS.saveToFile
    }

    StringSetting {
        settingKey: "saveDirectory"
        label: "Save directory"
        description: "Empty for the Screenshots folder inside your Pictures directory"
        placeholder: "~/Pictures/Screenshots"
        defaultValue: Config.DEFAULTS.saveDirectory
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Notify when done"
        description: "Saved files get Open and Open Folder actions"
        defaultValue: Config.DEFAULTS.notify
    }

    SectionTitle { text: "Frozen frame"; topPadding: Theme.spacingM }

    SelectionSetting {
        settingKey: "backend"
        label: "Backend"
        description: "screencopy shows the frame sooner (about 50 ms) but crashes stock Quickshell 0.3.1 and older (quickshell#1094). Choose it only with a fixed Quickshell."
        options: [
            { "label": "cli (default)", "value": "cli" },
            { "label": "screencopy (needs a fixed Quickshell)", "value": "screencopy" }
        ]
        defaultValue: Config.DEFAULTS.backend
    }
}
