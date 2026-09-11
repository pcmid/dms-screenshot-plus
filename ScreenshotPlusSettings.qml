import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "lib/Config.js" as Config

// Settings page (DMS Settings → Plugins → Screenshot+).
// Defaults come from lib/Config.js so the daemon and this page never disagree.
PluginSettings {
    id: root
    pluginId: "screenshotPlus"

    // ── Tools ────────────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        text: "工具栏"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "关掉的工具不显示在截图工具栏里，快捷键也失效。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting { settingKey: Config.toolEnabledKey("select");      label: "选择 (S)";   description: "点选已画的标注，拖动移动，Delete 删除，双击文字编辑"; defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("rect");        label: "矩形 (R)";   defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("ellipse");     label: "椭圆 (E)";   defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("line");        label: "直线 (L)";   defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("arrow");       label: "箭头 (A)";   defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("pen");         label: "画笔 (P)";   defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("highlighter"); label: "荧光笔 (H)"; description: "半透明粗笔，用来标重点"; defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("text");        label: "文字 (T)";   description: "Enter 提交，Shift+Enter 换行，Esc 取消"; defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("mosaic");      label: "马赛克 (M)"; defaultValue: true }
    ToggleSetting { settingKey: Config.toolEnabledKey("number");      label: "序号 (N)";   description: "点一下放一个自增编号，删掉中间的会自动重排"; defaultValue: true }

    // ── Defaults ─────────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        text: "默认样式"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ColorSetting {
        settingKey: "defaultColor"
        label: "默认颜色"
        description: "每次截图开始时的标注颜色；截图中可在工具栏临时更换"
        defaultValue: Config.DEFAULTS.defaultColor
    }

    SelectionSetting {
        settingKey: "defaultWidthPreset"
        label: "默认粗细"
        description: "S / M / L / XL 对每个工具各有一套具体数值（线宽、字号、马赛克块大小、序号半径）"
        options: [
            { "label": "S  细", "value": "S" },
            { "label": "M  中", "value": "M" },
            { "label": "L  粗", "value": "L" },
            { "label": "XL 特粗", "value": "XL" }
        ]
        defaultValue: Config.DEFAULTS.defaultWidthPreset
    }

    // ── Output ───────────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        text: "输出"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "copyToClipboard"
        label: "复制到剪贴板"
        description: "Enter / ✓ 时复制。工具栏的「复制」按钮不受此项影响"
        defaultValue: Config.DEFAULTS.copyToClipboard
    }

    ToggleSetting {
        settingKey: "saveToFile"
        label: "保存到文件"
        description: "Enter / ✓ 时同时落盘。工具栏的「保存」按钮（Ctrl+S）不受此项影响"
        defaultValue: Config.DEFAULTS.saveToFile
    }

    StringSetting {
        settingKey: "saveDirectory"
        label: "保存目录"
        description: "留空 = 系统图片目录下的 Screenshots"
        placeholder: "~/Pictures/Screenshots"
        defaultValue: Config.DEFAULTS.saveDirectory
    }

    ToggleSetting {
        settingKey: "notify"
        label: "完成后通知"
        description: "保存到文件时通知里带「打开 / 打开目录」按钮"
        defaultValue: Config.DEFAULTS.notify
    }

    // ── Backend ──────────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        text: "冻结帧后端"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SelectionSetting {
        settingKey: "backend"
        label: "抓帧方式"
        description: "screencopy 更快（约 50ms 出帧），但原版 Quickshell ≤ 0.3.1 会因 quickshell#1094 崩掉整个 shell。只有确认 Quickshell 已修复时才选它。"
        options: [
            { "label": "cli — 稳定（默认）", "value": "cli" },
            { "label": "screencopy — 快，需要修复过的 Quickshell", "value": "screencopy" }
        ]
        defaultValue: Config.DEFAULTS.backend
    }
}
