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

    component SectionTitle: StyledText {
        width: parent.width
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SectionTitle { text: I18n.trFor("screenshotPlus", "Toolbar") }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Repeater {
            model: Tools.TOOLS
            delegate: ToggleSetting {
                required property var modelData
                settingKey: Config.toolEnabledKey(modelData.id)
                label: I18n.trFor("screenshotPlus", modelData.label) + " (" + modelData.key + ")"
                defaultValue: true
            }
        }
    }

    SectionTitle { text: I18n.trFor("screenshotPlus", "Default style"); topPadding: Theme.spacingM }

    ColorSetting {
        settingKey: "defaultColor"
        label: I18n.trFor("screenshotPlus", "Color")
        defaultValue: Config.DEFAULTS.defaultColor
    }

    SelectionSetting {
        settingKey: "defaultWidthPreset"
        label: I18n.trFor("screenshotPlus", "Size")
        options: [
            { "label": "S", "value": "S" },
            { "label": "M", "value": "M" },
            { "label": "L", "value": "L" },
            { "label": "XL", "value": "XL" }
        ]
        defaultValue: Config.DEFAULTS.defaultWidthPreset
    }

    SectionTitle { text: I18n.trFor("screenshotPlus", "Output"); topPadding: Theme.spacingM }

    ToggleSetting {
        settingKey: "copyToClipboard"
        label: I18n.trFor("screenshotPlus", "Copy to clipboard")
        defaultValue: Config.DEFAULTS.copyToClipboard
    }

    ToggleSetting {
        settingKey: "saveToFile"
        label: I18n.trFor("screenshotPlus", "Save to file")
        defaultValue: Config.DEFAULTS.saveToFile
    }

    StringSetting {
        settingKey: "saveDirectory"
        label: I18n.trFor("screenshotPlus", "Save directory")
        placeholder: "~/Pictures/Screenshots"
        defaultValue: Config.DEFAULTS.saveDirectory
    }

    ToggleSetting {
        settingKey: "notify"
        label: I18n.trFor("screenshotPlus", "Notify when done")
        defaultValue: Config.DEFAULTS.notify
    }

    // A direct child of PluginSettings: nested settings never receive the
    // pluginService and would show their defaults.
    SelectionSetting {
        settingKey: "backend"
        label: I18n.trFor("screenshotPlus", "Backend")
        topPadding: Theme.spacingM
        description: I18n.trFor("screenshotPlus", "cli grabs the screen with dms screenshot and works with any Quickshell. screencopy shows the frame about three times sooner but crashes current stock Quickshell when the overlay closes (quickshell#1094, fix pending); use it only with a Quickshell that includes the fix.")
        options: [
            { "label": "cli", "value": "cli" },
            { "label": "screencopy", "value": "screencopy" }
        ]
        defaultValue: Config.DEFAULTS.backend
    }
}
