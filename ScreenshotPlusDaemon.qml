import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "lib/Tools.js" as Tools
import "lib/Config.js" as Config
import "lib/Hit.js" as Hit

// Screenshot+ daemon — orchestration and shared state.
//
// It owns everything that must be identical across monitors (the selection
// rectangle, the annotation strokes and their history, tool/style state, the
// frozen frames) and hands it to CaptureOverlay, which draws one PanelWindow
// per screen.
//
// Coordinate convention: selection and strokes are stored in GLOBAL LOGICAL
// coordinates (the compositor's layout space, e.g. DP-1 = 0,0,1920,1080).
// Each overlay subtracts its own screen origin.
PluginComponent {
    id: root

    // ── Session state ────────────────────────────────────────────────────────
    property bool active: false
    property bool capturing: false

    // "cli" shells out to `dms screenshot` and loads a PNG (~80ms to a dimmed
    // screen, ~170ms to the frame). "screencopy" reads the compositor's frame
    // through ScreencopyView (~50ms to the frame) but crashes stock Quickshell
    // <= 0.3.1: its wlr screencopy backend binds a second wl_output carrying
    // Qt's own listener, QtWayland mistakes it for a screen and later
    // dereferences it after it is freed — quickshell-mirror/quickshell#1094.
    // The default stays "cli" until that fix ships.
    // One-off override for the next capture (captureWith); "" follows settings.
    property string backendOverride: ""
    readonly property string backend: {
        const b = backendOverride !== "" ? backendOverride : Config.read(pluginData, "backend")
        return b === "screencopy" ? "screencopy" : "cli"
    }

    // screenName -> "/tmp/dmsplus-freeze-<name>-<stamp>.png"
    property var freezes: ({})
    // screenName -> { x, y, width, height, scale }
    property var screenInfo: ({})

    // ── Settings (see lib/Config.js for the defaults) ────────────────────────
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

    // ── Selection (global logical coords) ────────────────────────────────────
    property bool hasSelection: false
    property real selX: 0
    property real selY: 0
    property real selW: 0
    property real selH: 0

    // ── Annotation ───────────────────────────────────────────────────────────
    property string activeTool: ""
    property color strokeColor: Config.DEFAULTS.defaultColor
    // toolId -> px. Every tool keeps its own size for the session.
    property var toolWidths: Tools.defaultWidths(Tools.DEFAULT_PRESET)
    readonly property real currentWidth: toolWidths[activeTool] !== undefined ? toolWidths[activeTool] : 3

    // Snapshot history. `strokes` is replaced wholesale on every change and
    // stroke objects are never mutated once they are in it, so snapshots are
    // cheap (arrays of shared references) and QML always sees the change.
    property var strokes: []
    property var history: []
    property var future: []
    property int nextStrokeId: 1
    readonly property bool canUndo: history.length > 0
    readonly property bool canRedo: future.length > 0

    property int selectedId: -1
    property bool textEditing: false   // mirrored from the overlay, for status

    // "default" follows the settings; "copy" / "save" are one-off overrides
    // from the toolbar buttons or IPC.
    property string exportIntent: "default"
    property string lastSavedPath: ""

    // While the colour picker is open the overlay drops its exclusive
    // keyboard grab so the picker can be typed into.
    property bool pickerOpen: false

    // Bumped to ask the overlay owning the selection to render and save.
    signal exportRequested

    property int _pendingGrabs: 0
    property var _grabAcc: ({})
    property string _picturesDir: ""

    // True once the overlay actually has decoded pixels on screen.
    property bool frameShown: false
    property bool _pendingFinish: false

    // Timing instrumentation, surfaced through `status`.
    property double _t0: 0
    property int lastGrabMs: 0
    property int lastReadyMs: 0
    property string lastError: ""

    // ── Entry points ─────────────────────────────────────────────────────────

    function capture() {
        if (root.active || root.capturing) {
            console.warn("screenshotPlus: capture already in progress")
            return
        }
        root._resetSession()
        root._t0 = Date.now()

        if (root._picturesDir === "" && root.saveDirectory.trim() === "") {
            Proc.runCommand("screenshotPlus.xdgpics", ["xdg-user-dir", "PICTURES"],
                            (out, code) => { if (code === 0 && out.trim()) root._picturesDir = out.trim() },
                            0, 3000)
        }

        // Close popouts so they don't end up baked into the frozen frame.
        PopoutManager.screenshotActive = true
        root._collectScreenInfo()

        if (root.backend === "screencopy") {
            root.capturing = false
            root.active = true
            return
        }

        // Fire the grab BEFORE mapping the overlay: `dms screenshot` is served
        // by this same process, and a new layer's first frame competing with
        // it roughly doubles the latency.
        root.capturing = true
        root._grabFreezes()
        // The overlay is fully transparent at this point, so it cannot
        // contaminate the in-flight grab, but the pointer is live immediately.
        root.active = true
    }

    function _collectScreenInfo() {
        const screens = Quickshell.screens
        const info = {}
        for (let i = 0; i < screens.length; i++) {
            const sc = screens[i]
            info[sc.name] = {
                "x": sc.x, "y": sc.y, "width": sc.width, "height": sc.height,
                "scale": CompositorService.getScreenScale(sc)
            }
        }
        root.screenInfo = info
    }

    function noteFrameReady() {
        if (root._t0 > 0) {
            root.lastReadyMs = Date.now() - root._t0
            root._t0 = 0
        }
        root.frameShown = true
        if (root._pendingFinish) {
            root._pendingFinish = false
            root.finish()
        }
    }

    function cancel() {
        root._teardown()
    }

    function finish() {
        root.finishWith("default")
    }

    function finishWith(intent) {
        if (!root.hasSelection || root.selW < 1 || root.selH < 1) {
            root._teardown()
            return
        }
        root.exportIntent = intent || "default"
        // The overlay maps before the frame lands, so Enter can arrive while
        // the picture is still decoding — queue it for noteFrameReady().
        if (root.capturing || !root.frameShown) {
            root._pendingFinish = true
            return
        }
        root.exportRequested()
    }

    // ── Annotation API ───────────────────────────────────────────────────────

    // The only write path into `strokes`.
    function commitStrokes(next) {
        root.history = [...root.history, root.strokes]
        root.strokes = next
        root.future = []
        root._validateSelection()
    }

    function pushStroke(stroke) {
        const s = Object.assign({}, stroke, { "id": root.nextStrokeId })
        root.nextStrokeId++
        root.commitStrokes([...root.strokes, s])
        return s.id
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
        const i = Hit.indexOfId(root.strokes, id)
        if (i === -1)
            return
        root.commitStrokes(root.strokes.filter(s => s.id !== id))
        if (root.selectedId === id)
            root.selectedId = -1
    }

    function undo() {
        if (root.history.length === 0)
            return
        root.future = [root.strokes, ...root.future]
        root.strokes = root.history[root.history.length - 1]
        root.history = root.history.slice(0, -1)
        root._validateSelection()
    }

    function redo() {
        if (root.future.length === 0)
            return
        root.history = [...root.history, root.strokes]
        root.strokes = root.future[0]
        root.future = root.future.slice(1)
        root._validateSelection()
    }

    function _validateSelection() {
        if (root.selectedId >= 0 && Hit.indexOfId(root.strokes, root.selectedId) === -1)
            root.selectedId = -1
    }

    function select(id) {
        root.selectedId = (id >= 0 && Hit.indexOfId(root.strokes, id) !== -1) ? id : -1
    }

    function setTool(tool) {
        if (tool !== "" && (Tools.byId(tool) === null || root.enabledTools.indexOf(tool) === -1))
            return false
        root.activeTool = root.activeTool === tool ? "" : tool
        return true
    }

    function setToolWidth(tool, px) {
        const next = Object.assign({}, root.toolWidths)
        next[tool] = px
        root.toolWidths = next
    }

    function setSelection(x, y, w, h) {
        root.selX = x
        root.selY = y
        root.selW = w
        root.selH = h
        root.hasSelection = w >= 1 && h >= 1
    }

    // ── Frozen frames ────────────────────────────────────────────────────────

    function _grabFreezes() {
        const screens = Quickshell.screens
        if (!screens || screens.length === 0) {
            console.warn("screenshotPlus: no screens")
            root._teardown()
            return
        }

        const stamp = Date.now()
        root._pendingGrabs = screens.length
        root._grabAcc = {}

        for (let i = 0; i < screens.length; i++) {
            const name = screens[i].name
            const fname = `dmsplus-freeze-${name}-${stamp}.png`
            Proc.runCommand("screenshotPlus.freeze." + name,
                            ["dms", "screenshot", "output", "-o", name,
                             "--no-clipboard", "--no-notify",
                             "--dir", "/tmp", "--filename", fname,
                             "--format", "png", "--json"],
                            (stdout, exitCode) => root._onFreezeDone(name, "/tmp/" + fname, stdout, exitCode),
                            0, 15000)
        }
    }

    function _onFreezeDone(name, path, stdout, exitCode) {
        let ok = exitCode === 0
        if (ok) {
            try {
                ok = JSON.parse(stdout.trim()).status === "success"
            } catch (e) {
                ok = false
            }
        }
        if (!ok) {
            root.lastError = "grab " + name + " exit=" + exitCode + " out=" + String(stdout).trim().slice(0, 200)
            console.warn("screenshotPlus:", root.lastError)
            root._teardown()
            return
        }

        const acc = Object.assign({}, root._grabAcc)
        acc[name] = path
        root._grabAcc = acc

        root._pendingGrabs--
        if (root._pendingGrabs > 0)
            return

        root.lastGrabMs = root._t0 > 0 ? Date.now() - root._t0 : 0
        root.freezes = root._grabAcc
        root.capturing = false
    }

    // ── Export result handling ───────────────────────────────────────────────

    function resolvedSaveDir() {
        const d = root.saveDirectory.trim().replace(/\/+$/, "")
        if (d !== "")
            return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d
        const pics = root._picturesDir !== "" ? root._picturesDir : Quickshell.env("HOME") + "/Pictures"
        return pics + "/Screenshots"
    }

    // Called by the overlay once its grab has been written to `path`.
    function onExported(path) {
        if (!path) {
            root._teardown()
            return
        }

        const intent = root.exportIntent
        root.exportIntent = "default"
        const doCopy = intent === "copy" || (intent === "default" && root.copyToClipboard)
        const doSave = intent === "save" || (intent === "default" && root.saveToFile)

        if (doCopy) {
            DMSService.sendRequest("clipboard.copyFile", { "filePath": path }, resp => {
                if (resp && resp.error)
                    console.warn("screenshotPlus: clipboard failed -", resp.error)
            })
        }

        const q = root._shellQuote
        const notifyBase = " --app Screenshot+ --icon screenshot_region"
        if (doSave) {
            const dir = root.resolvedSaveDir()
            const dest = dir + "/screenshot-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss") + ".png"
            let cmd = "mkdir -p -- " + q(dir) + " && cp -- " + q(path) + " " + q(dest)
            if (root.notify) {
                const body = doCopy ? "已保存并复制到剪贴板" : "已保存"
                cmd += " && dms notify Screenshot+ " + q(body) + " --file " + q(dest) + notifyBase
            }
            cmd += " || dms notify Screenshot+ " + q("保存失败：" + dir) + notifyBase
            Quickshell.execDetached(["sh", "-c", cmd])
            root.lastSavedPath = dest
        } else if (doCopy && root.notify) {
            Quickshell.execDetached(["dms", "notify", "Screenshot+", "已复制到剪贴板",
                                     "--app", "Screenshot+", "--icon", "screenshot_region"])
        }

        // Give the notification daemon time to read the file before it goes.
        Quickshell.execDetached(["sh", "-c", "sleep 10 && rm -f -- " + q(path)])
        root._teardown()
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    function _resetSession() {
        root.hasSelection = false
        root.selX = 0
        root.selY = 0
        root.selW = 0
        root.selH = 0
        root.activeTool = ""
        root.strokeColor = root.defaultColor
        root.toolWidths = Tools.defaultWidths(root.defaultWidthPreset)
        root.strokes = []
        root.history = []
        root.future = []
        root.nextStrokeId = 1
        root.selectedId = -1
        root.textEditing = false
        root.exportIntent = "default"
        root.pickerOpen = false
        root.freezes = ({})
        root.screenInfo = ({})
        root._grabAcc = ({})
        root._pendingGrabs = 0
        root.frameShown = false
        root._pendingFinish = false
    }

    function _teardown() {
        const stale = root.freezes
        root.active = false
        root.capturing = false
        root._resetSession()
        root.backendOverride = ""
        PopoutManager.screenshotActive = false
        for (const name in stale)
            Quickshell.execDetached(["rm", "-f", "--", stale[name]])
    }

    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // PluginComponent only loads settings; writing goes through the service.
    // Mirror the value locally so bindings update without waiting for the
    // pluginDataChanged round trip.
    function savePluginData(key, value) {
        if (pluginService && pluginId)
            pluginService.savePluginData(pluginId, key, value)
        const next = Object.assign({}, root.pluginData)
        next[key] = value
        root.pluginData = next
    }

    // ── Test helpers (used by the IPC below) ─────────────────────────────────

    // A representative stroke of `tool` inside the rectangle r = {x,y,w,h}.
    function _sampleStroke(tool, r) {
        const w = root.toolWidths[tool] !== undefined ? root.toolWidths[tool] : 3
        const color = String(root.strokeColor)
        const P = (fx, fy) => ({ "x": r.x + r.w * fx, "y": r.y + r.h * fy })
        switch (Tools.kindOf(tool)) {
        case "drag":
            return { "tool": tool, "color": color, "width": w, "points": [P(0.15, 0.15), P(0.85, 0.85)] }
        case "path":
            return { "tool": tool, "color": color, "width": w,
                     "points": [P(0.1, 0.8), P(0.3, 0.2), P(0.5, 0.8), P(0.7, 0.2), P(0.9, 0.8)] }
        case "click":
            return { "tool": tool, "color": color, "width": w, "points": [P(0.5, 0.5)] }
        case "text": {
            const lh = Math.round(w * 1.3)
            return { "tool": tool, "color": color, "width": w, "points": [P(0.1, 0.2)],
                     "text": "Test\n测试", "w": Math.round(w * 0.6 * 4), "h": lh * 2, "lineHeight": lh, "font": Theme.fontFamily }
        }
        }
        return null
    }

    // ── IPC ──────────────────────────────────────────────────────────────────

    IpcHandler {
        // Quickshell rejects a call that supplies fewer arguments than the
        // signature declares, so the no-arg form has to be its own function.
        function capture(): string {
            root.capture()
            return "OK"
        }

        // One-off backend override; does not persist.
        function captureWith(backend: string): string {
            if (backend !== "screencopy" && backend !== "cli")
                return "BAD_ARGS"
            root.backendOverride = backend
            root.capture()
            return "OK"
        }

        function setBackend(backend: string): string {
            if (backend !== "screencopy" && backend !== "cli")
                return "BAD_ARGS"
            root.savePluginData("backend", backend)
            return "OK"
        }

        function cancel(): string {
            root.cancel()
            return "OK"
        }

        function finish(): string {
            if (!root.active)
                return "NOT_ACTIVE"
            root.finish()
            return "OK"
        }

        // intent: default | copy | save
        function finishWith(intent: string): string {
            if (!root.active)
                return "NOT_ACTIVE"
            if (["default", "copy", "save"].indexOf(intent) === -1)
                return "BAD_ARGS"
            root.finishWith(intent)
            return "OK"
        }

        function status(): string {
            return JSON.stringify({
                "active": root.active,
                "capturing": root.capturing,
                "hasSelection": root.hasSelection,
                "sel": [root.selX, root.selY, root.selW, root.selH],
                "tool": root.activeTool,
                "color": String(root.strokeColor),
                "widths": root.toolWidths,
                "strokes": root.strokes.length,
                "history": root.history.length,
                "future": root.future.length,
                "selectedId": root.selectedId,
                "textEditing": root.textEditing,
                "enabledTools": root.enabledTools,
                "config": {
                    "backend": root.backend, "defaultColor": root.defaultColor,
                    "defaultWidthPreset": root.defaultWidthPreset,
                    "copyToClipboard": root.copyToClipboard, "saveToFile": root.saveToFile,
                    "saveDirectory": root.resolvedSaveDir(), "notify": root.notify
                },
                "lastSaved": root.lastSavedPath,
                "grabMs": root.lastGrabMs,
                "readyMs": root.lastReadyMs,
                "error": root.lastError
            })
        }

        // Set the selection without the mouse (global logical coords).
        function select(x: string, y: string, w: string, h: string): string {
            if (!root.active)
                return "NOT_ACTIVE"
            const nx = parseFloat(x), ny = parseFloat(y), nw = parseFloat(w), nh = parseFloat(h)
            if (![nx, ny, nw, nh].every(v => isFinite(v)) || nw < 1 || nh < 1)
                return "BAD_ARGS"
            root.setSelection(nx, ny, nw, nh)
            return "OK"
        }

        function setTool(tool: string): string {
            return root.setTool(tool) ? "OK" : "BAD_TOOL"
        }

        function setColor(color: string): string {
            if (!/^#[0-9a-fA-F]{6}$/.test(color))
                return "BAD_ARGS"
            root.strokeColor = color
            return "OK"
        }

        // Legacy self-test: a rectangle and a diagonal pen stroke.
        function testStroke(): string {
            if (!root.hasSelection)
                return "NO_SELECTION"
            const r = { "x": root.selX, "y": root.selY, "w": root.selW, "h": root.selH }
            root.pushStroke({ "tool": "rect", "color": "#ff5252", "width": 4,
                              "points": [{ "x": r.x + r.w * 0.2, "y": r.y + r.h * 0.2 }, { "x": r.x + r.w * 0.8, "y": r.y + r.h * 0.8 }] })
            root.pushStroke({ "tool": "pen", "color": "#4caf50", "width": 4,
                              "points": [{ "x": r.x + r.w * 0.2, "y": r.y + r.h * 0.8 }, { "x": r.x + r.w * 0.5, "y": r.y + r.h * 0.5 }, { "x": r.x + r.w * 0.8, "y": r.y + r.h * 0.2 }] })
            return "OK"
        }

        // One representative stroke of `tool` filling the selection.
        function testStrokeTool(tool: string): string {
            if (!root.hasSelection)
                return "NO_SELECTION"
            const s = root._sampleStroke(tool, { "x": root.selX, "y": root.selY, "w": root.selW, "h": root.selH })
            if (!s)
                return "BAD_TOOL"
            return "OK " + root.pushStroke(s)
        }

        // Every enabled annotation tool once, laid out in a grid.
        function testAll(): string {
            if (!root.hasSelection)
                return "NO_SELECTION"
            const tools = root.enabledTools.filter(t => Tools.kindOf(t) !== "select")
            const cols = 3
            const rows = Math.ceil(tools.length / cols)
            const cw = root.selW / cols, ch = root.selH / rows
            const ids = []
            for (let i = 0; i < tools.length; i++) {
                const cell = { "x": root.selX + (i % cols) * cw, "y": root.selY + Math.floor(i / cols) * ch, "w": cw, "h": ch }
                const s = root._sampleStroke(tools[i], cell)
                if (s)
                    ids.push(tools[i] + "=" + root.pushStroke(s))
            }
            return "OK " + ids.join(" ")
        }

        function hitTest(x: string, y: string): string {
            const s = Hit.strokeAt(root.strokes, parseFloat(x), parseFloat(y))
            return s ? JSON.stringify({ "id": s.id, "tool": s.tool }) : "null"
        }

        function selectStroke(id: string): string {
            root.select(parseInt(id, 10))
            return root.selectedId >= 0 ? "OK" : "NONE"
        }

        function moveSelected(dx: string, dy: string): string {
            const i = Hit.indexOfId(root.strokes, root.selectedId)
            if (i === -1)
                return "NONE"
            root.replaceStroke(root.selectedId, Hit.translate(root.strokes[i], parseFloat(dx), parseFloat(dy)))
            return "OK"
        }

        function deleteSelected(): string {
            if (root.selectedId < 0)
                return "NONE"
            root.deleteStroke(root.selectedId)
            return "OK"
        }

        function undo(): string {
            root.undo()
            return "OK " + root.strokes.length
        }

        function redo(): string {
            root.redo()
            return "OK " + root.strokes.length
        }

        function strokesJson(): string {
            return JSON.stringify(root.strokes)
        }

        target: "screenshotPlus"
        enabled: true
    }

    // ── Wiring ───────────────────────────────────────────────────────────────

    CaptureOverlay {
        ctl: root
    }

    Component.onCompleted: {
        if (pluginService && pluginId)
            pluginService.pluginInstances[pluginId] = root
        // Resolve the XDG pictures directory once, so the very first save
        // doesn't have to guess.
        Proc.runCommand("screenshotPlus.xdgpics", ["xdg-user-dir", "PICTURES"],
                        (out, code) => { if (code === 0 && out.trim()) root._picturesDir = out.trim() },
                        0, 3000)
    }

    Component.onDestruction: {
        if (root.active)
            root._teardown()
        if (pluginService && pluginId && pluginService.pluginInstances[pluginId] === root)
            delete pluginService.pluginInstances[pluginId]
    }
}
