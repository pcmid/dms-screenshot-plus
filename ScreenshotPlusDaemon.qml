import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "lib/Tools.js" as Tools
import "lib/Config.js" as Config
import "lib/Hit.js" as Hit

// State shared by every screen during a capture: the selection, the strokes
// and their history, the tool and style, the frozen frames. CaptureOverlay
// puts one window per screen on top of this.
//
// The selection and the strokes are stored in global logical coordinates
// (the compositor's layout space); each overlay subtracts its screen origin.
PluginComponent {
    id: root

    property bool active: false
    property bool capturing: false     // cli backend: frames are being grabbed
    property bool frameShown: false    // the overlay shows the frozen frame; export waits for it

    // ── Settings ─────────────────────────────────────────────────────────────

    // "cli" shells out to `dms screenshot`. "screencopy" reads the frame via
    // ScreencopyView, which crashes current stock Quickshell (quickshell#1094, fix pending).
    readonly property string backend: Config.read(pluginData, "backend") === "screencopy" ? "screencopy" : "cli"
    readonly property var enabledTools: Tools.TOOLS.filter(t => Config.toolEnabled(pluginData, t.id)).map(t => t.id)
    readonly property string defaultColor: {
        const v = Config.read(pluginData, "defaultColor")
        return typeof v === "string" && v !== "" ? v : Config.DEFAULTS.defaultColor
    }
    readonly property string defaultWidthPreset: Config.read(pluginData, "defaultWidthPreset")
    readonly property bool copyToClipboard: Config.read(pluginData, "copyToClipboard") !== false
    readonly property bool saveToFile: Config.read(pluginData, "saveToFile") === true
    readonly property string saveDirectory: String(Config.read(pluginData, "saveDirectory") || "")
    readonly property bool notify: Config.read(pluginData, "notify") !== false

    // ── Screens and frozen frames ────────────────────────────────────────────

    property var screenInfo: ({})      // name -> { x, y, width, height, scale }
    property var freezes: ({})         // name -> frozen frame PNG (cli backend)
    property int _pendingGrabs: 0
    property var _grabbed: ({})

    // ── Selection ────────────────────────────────────────────────────────────

    property bool hasSelection: false
    property real selX: 0
    property real selY: 0
    property real selW: 0
    property real selH: 0

    // ── Tool and style ───────────────────────────────────────────────────────

    property string activeTool: ""
    property color strokeColor: Config.DEFAULTS.defaultColor
    property var toolWidths: ({})      // tool id -> px, remembered per tool for the session
    readonly property real currentWidth: toolWidths[activeTool] !== undefined ? toolWidths[activeTool] : 3
    property bool pickerOpen: false    // the overlay releases its keyboard grab for the color picker

    // ── Strokes ──────────────────────────────────────────────────────────────
    // `strokes` is replaced wholesale on every change and stroke objects are
    // never mutated once committed, so history snapshots share references.

    property var strokes: []
    property var history: []
    property var future: []
    property int nextStrokeId: 1
    property int selectedId: -1
    readonly property bool canUndo: history.length > 0
    readonly property bool canRedo: future.length > 0

    // ── Export ───────────────────────────────────────────────────────────────

    property string exportIntent: "default"   // default (follow settings) | copy | save
    property bool _finishPending: false
    signal exportRequested                    // handled by the overlay that owns the selection

    readonly property string _finalizeScript: Qt.resolvedUrl("lib/finalize.sh").toString().replace(/^file:\/\//, "")

    // ── Session ──────────────────────────────────────────────────────────────

    function capture() {
        if (root.active || root.capturing)
            return false
        root._resetSession()
        PopoutManager.screenshotActive = true   // closes popouts before the grab
        root._collectScreenInfo()
        if (root.backend === "cli") {
            // Start the grab before mapping the overlay: `dms screenshot` runs
            // in this process and a new layer's first frame would compete with
            // it. The overlay stays fully transparent until the grab returns.
            root.capturing = true
            root._grabFreezes()
        }
        root.active = true
        return true
    }

    function cancel() {
        root._endSession()
    }

    function finish(intent) {
        if (!root.hasSelection) {
            root._endSession()
            return
        }
        root.exportIntent = intent || "default"
        // Enter can arrive before the frame is on screen; noteFrameReady() retries.
        if (root.capturing || !root.frameShown) {
            root._finishPending = true
            return
        }
        root.exportRequested()
    }

    function noteFrameReady() {
        root.frameShown = true
        if (root._finishPending) {
            root._finishPending = false
            root.finish(root.exportIntent)
        }
    }

    function _collectScreenInfo() {
        const info = {}
        for (const sc of Quickshell.screens)
            info[sc.name] = { "x": sc.x, "y": sc.y, "width": sc.width, "height": sc.height,
                              "scale": CompositorService.getScreenScale(sc) }
        root.screenInfo = info
    }

    function _resetSession() {
        root.frameShown = false
        root._finishPending = false
        root.exportIntent = "default"
        root.screenInfo = {}
        root.freezes = {}
        root._grabbed = {}
        root._pendingGrabs = 0
        root.setSelection(0, 0, 0, 0)
        root.activeTool = ""
        root.strokeColor = root.defaultColor
        root.toolWidths = Tools.defaultWidths(root.defaultWidthPreset)
        root.pickerOpen = false
        root.strokes = []
        root.history = []
        root.future = []
        root.nextStrokeId = 1
        root.selectedId = -1
    }

    function _endSession() {
        const stale = root.freezes
        root.active = false
        root.capturing = false
        PopoutManager.screenshotActive = false
        root._resetSession()
        for (const name in stale)
            Quickshell.execDetached(["rm", "-f", "--", stale[name]])
    }

    // ── Selection and strokes ────────────────────────────────────────────────

    // Whole logical pixels: a selection at a fractional offset or size makes
    // the frame copy inside it resample and look soft.
    function setSelection(x, y, w, h) {
        const x0 = Math.round(x)
        const y0 = Math.round(y)
        root.selX = x0
        root.selY = y0
        root.selW = Math.round(x + w) - x0
        root.selH = Math.round(y + h) - y0
        root.hasSelection = root.selW >= 1 && root.selH >= 1
    }

    function setTool(tool) {
        if (tool !== "" && root.enabledTools.indexOf(tool) === -1)
            return
        root.activeTool = root.activeTool === tool ? "" : tool
    }

    function setToolWidth(tool, px) {
        root.toolWidths = Object.assign({}, root.toolWidths, { [tool]: px })
    }

    function select(id) {
        root.selectedId = id >= 0 && Hit.indexOfId(root.strokes, id) !== -1 ? id : -1
    }

    // The only write path into `strokes`.
    function commitStrokes(next) {
        root.history = [...root.history, root.strokes]
        root.strokes = next
        root.future = []
        root.select(root.selectedId)
    }

    function pushStroke(stroke) {
        const id = root.nextStrokeId++
        root.commitStrokes([...root.strokes, Object.assign({}, stroke, { "id": id })])
        return id
    }

    function replaceStroke(id, stroke) {
        const i = Hit.indexOfId(root.strokes, id)
        if (i === -1)
            return
        const next = root.strokes.slice()
        next[i] = Object.assign({}, stroke, { "id": id })
        root.commitStrokes(next)
    }

    function deleteStroke(id) {
        if (Hit.indexOfId(root.strokes, id) !== -1)
            root.commitStrokes(root.strokes.filter(s => s.id !== id))
    }

    function undo() {
        if (root.history.length === 0)
            return
        root.future = [root.strokes, ...root.future]
        root.strokes = root.history[root.history.length - 1]
        root.history = root.history.slice(0, -1)
        root.select(root.selectedId)
    }

    function redo() {
        if (root.future.length === 0)
            return
        root.history = [...root.history, root.strokes]
        root.strokes = root.future[0]
        root.future = root.future.slice(1)
        root.select(root.selectedId)
    }

    // ── Frozen frames (cli backend) ──────────────────────────────────────────

    function _grabFreezes() {
        const screens = Quickshell.screens
        if (screens.length === 0) {
            console.warn("screenshotPlus: no screens")
            root._endSession()
            return
        }
        const stamp = Date.now()
        root._pendingGrabs = screens.length
        for (const sc of screens) {
            const name = sc.name
            const path = `/tmp/screenshot-plus-freeze-${name}-${stamp}.png`
            Proc.runCommand("screenshotPlus.freeze." + name,
                            ["dms", "screenshot", "output", "-o", name, "--no-clipboard", "--no-notify",
                             "--dir", "/tmp", "--filename", path.slice(5), "--format", "png", "--json"],
                            (stdout, exitCode) => root._onFreezeDone(name, path, stdout, exitCode),
                            0, 15000)
        }
    }

    function _onFreezeDone(name, path, stdout, exitCode) {
        let ok = exitCode === 0
        try {
            ok = ok && JSON.parse(stdout).status === "success"
        } catch (e) {
            ok = false
        }
        if (!ok) {
            console.warn("screenshotPlus: grabbing", name, "failed:", exitCode, String(stdout).trim().slice(0, 200))
            root._endSession()
            return
        }
        root._grabbed = Object.assign({}, root._grabbed, { [name]: path })
        if (--root._pendingGrabs > 0)
            return
        root.freezes = root._grabbed
        root.capturing = false
    }

    // ── Export result ────────────────────────────────────────────────────────

    // Called by the overlay once the selection has been written to `path`.
    function onExported(path) {
        const intent = root.exportIntent
        const copy = intent === "copy" || (intent === "default" && root.copyToClipboard)
        const save = intent === "save" || (intent === "default" && root.saveToFile)

        if (copy) {
            DMSService.sendRequest("clipboard.copyFile", { "filePath": path }, resp => {
                if (resp && resp.error)
                    console.warn("screenshotPlus: clipboard:", resp.error)
            })
        }

        const body = !root.notify ? ""
                   : save ? I18n.trFor("screenshotPlus", copy ? "Saved and copied to clipboard" : "Saved")
                   : copy ? I18n.trFor("screenshotPlus", "Copied to clipboard") : ""
        Quickshell.execDetached(["sh", root._finalizeScript, path, save ? "1" : "", save ? root._saveDir() : "",
                                 body, I18n.trFor("screenshotPlus", "Could not save to")])
        root._endSession()
    }

    // "" when unset: the script falls back to <Pictures>/Screenshots.
    function _saveDir() {
        const d = root.saveDirectory.trim().replace(/\/+$/, "")
        return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d
    }

    // ── IPC ──────────────────────────────────────────────────────────────────

    IpcHandler {
        target: "screenshotPlus"

        function capture(): string {
            return root.capture() ? "OK" : "BUSY"
        }

        function cancel(): string {
            root.cancel()
            return "OK"
        }

        function finish(): string {
            if (!root.active)
                return "NOT_ACTIVE"
            root.finish("default")
            return "OK"
        }
    }

    CaptureOverlay {
        ctl: root
    }

    Component.onDestruction: {
        if (root.active)
            root._endSession()
    }
}
