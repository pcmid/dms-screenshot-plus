import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "lib/Tools.js" as Tools
import "lib/Config.js" as Config
import "lib/Hit.js" as Hit
import "lib/Ocr.js" as Ocr

// State shared by every screen during a capture: the selection, the strokes
// and their history, the tool and style, the frozen frames. CaptureOverlay
// puts one window per screen on top of this; PinnedImage keeps exports on
// screen after the session.
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
    readonly property bool pinToScreen: Config.read(pluginData, "pinToScreen") === true
    readonly property string saveDirectory: String(Config.read(pluginData, "saveDirectory") || "")
    readonly property string fileNamePattern: String(Config.read(pluginData, "fileNamePattern") || "").trim()
    readonly property bool notify: Config.read(pluginData, "notify") !== false
    readonly property string oarPath: String(Config.read(pluginData, "oarPath") || "").trim()
    readonly property string oarArgs: String(Config.read(pluginData, "oarArgs") || "")

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
    property string hoverScreen: ""    // the screen under the pointer, for `F`

    // ── Region history ───────────────────────────────────────────────────────
    // The regions of the last exports, most recent first, in global logical
    // coordinates. Kept in DMS's plugin state so they survive a shell reload.
    // `<` and `>` walk through the ones that fall on a current screen.

    readonly property int maxRegions: 10
    property var regionHistory: []     // [{ x, y, w, h }]
    property bool _regionsLoaded: false
    property var _sessionRegions: []   // regionHistory restricted to the current screens
    property int regionIndex: -1       // entry of _sessionRegions shown by the selection, -1 = none
    property var _ownRegion: null      // the selection `<` replaced, brought back by `>`
    readonly property bool hasRegionHistory: _sessionRegions.length > 0

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

    property string exportIntent: "default"   // default (follow settings) | copy | save | pin
    property bool _finishPending: false
    signal exportRequested                    // handled by the overlay that owns the selection

    readonly property string _finalizeScript: Qt.resolvedUrl("lib/finalize.sh").toString().replace(/^file:\/\//, "")

    // Where frozen frames, exports and pictures for oar are written: private
    // to the user and gone at logout. Created when the plugin loads.
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/screenshot-plus"

    // Qt encodes PNG on the GUI thread and takes about a second for a large
    // selection. With ffmpeg or ImageMagick installed the overlay writes an
    // uncompressed PPM instead and finalize.sh converts it in the background.
    property string _encoder: ""
    readonly property string exportFormat: _encoder !== "" ? "ppm" : "png"

    // ── Pinned images ────────────────────────────────────────────────────────
    // Exports kept on screen as PinnedImage windows, one per entry. Entries
    // never change once added, since Variants would re-create the window;
    // the PNG a pin owns for copy and save lives in _pinFiles and is removed
    // when the pin closes.

    property var pins: []              // [{ id, screen, x, y, w, h, src }]
    property var _pinFiles: ({})       // id -> PNG path
    property int _nextPinId: 1

    // ── Text recognition ─────────────────────────────────────────────────────
    // A double-click on text inside the selection runs oar (oar-ocr, see
    // lib/Ocr.js) on the selection and turns on text mode: presses in the
    // selection then select text, as in a text box, and copying copies the
    // text, until text mode is left on purpose. The lines belong to the
    // selection they were recognized in and are dropped when it changes.

    readonly property bool ocrEnabled: oarPath !== ""
    property string ocrState: "idle"   // idle | running | ready | failed
    property var ocrLines: []          // Ocr.layout() lines, global logical
    property var _ocrRegion: null      // { x, y, w, h }: the selection recognized or being recognized
    property int _ocrToken: 0          // bumped to drop the recognition under way
    property var _ocrProc: null
    signal ocrFinished(string error)   // "" on success, else a message for the user

    property bool textMode: false
    property bool textMarked: false    // text mode from the OCR button: the recognized lines are outlined
    property var textAnchor: null      // { line, pos }, see lib/Ocr.js
    property var textFocus: null
    readonly property bool hasSelectedText: textMode && textAnchor !== null && textFocus !== null
                                            && Ocr.comparePos(textAnchor, textFocus) !== 0

    // ── Session ──────────────────────────────────────────────────────────────

    function capture() {
        if (root.active || root.capturing)
            return false
        root._resetSession()
        PopoutManager.screenshotActive = true   // closes popouts before the grab
        root._collectScreenInfo()
        root._loadRegionHistory()
        root._sessionRegions = root.regionHistory.filter(r => root._onAnyScreen(r))
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
        root.hoverScreen = ""
        root._sessionRegions = []
        root._ownRegion = null
        root.activeTool = ""
        root.strokeColor = root.defaultColor
        root.toolWidths = Tools.defaultWidths(root.defaultWidthPreset)
        root.pickerOpen = false
        root.strokes = []
        root.history = []
        root.future = []
        root.nextStrokeId = 1
        root.selectedId = -1
        root._resetOcr()
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
        root.regionIndex = -1
        const r = root._ocrRegion
        if (r !== null && (r.x !== root.selX || r.y !== root.selY || r.w !== root.selW || r.h !== root.selH))
            root._resetOcr()
    }

    // `F`: the whole screen.
    function selectScreen(name) {
        const s = root.screenInfo[name]
        if (!s)
            return
        root.select(-1)
        root.setSelection(s.x, s.y, s.width, s.height)
    }

    // `<` (step 1) and `>` (step -1): the selection becomes an earlier
    // region. Index -1 is the selection the user had before pressing `<`.
    function restoreRegion(step) {
        const i = root.regionIndex + step
        if (i < -1 || i >= root._sessionRegions.length)
            return
        if (root.regionIndex === -1)
            root._ownRegion = { "x": root.selX, "y": root.selY, "w": root.selW, "h": root.selH }
        const r = i === -1 ? root._ownRegion : root._sessionRegions[i]
        root.select(-1)
        root.setSelection(r.x, r.y, r.w, r.h)
        root.regionIndex = i
    }

    function _onAnyScreen(r) {
        for (const name in root.screenInfo) {
            const s = root.screenInfo[name]
            if (r.x < s.x + s.width && r.x + r.w > s.x && r.y < s.y + s.height && r.y + r.h > s.y)
                return true
        }
        return false
    }

    function _loadRegionHistory() {
        const svc = root.pluginService
        if (root._regionsLoaded || !svc || typeof svc.loadPluginState !== "function")
            return
        root._regionsLoaded = true
        const saved = svc.loadPluginState("screenshotPlus", "regionHistory", [])
        root.regionHistory = (Array.isArray(saved) ? saved : [])
            .filter(r => r && [r.x, r.y, r.w, r.h].every(Number.isFinite) && r.w >= 1 && r.h >= 1)
            .slice(0, root.maxRegions)
    }

    // Called on export: the selection moves to the front of the history.
    function _rememberRegion() {
        const r = { "x": root.selX, "y": root.selY, "w": root.selW, "h": root.selH }
        const rest = root.regionHistory.filter(e => e.x !== r.x || e.y !== r.y || e.w !== r.w || e.h !== r.h)
        root.regionHistory = [r, ...rest].slice(0, root.maxRegions)
        const svc = root.pluginService
        if (svc && typeof svc.savePluginState === "function")
            svc.savePluginState("screenshotPlus", "regionHistory", root.regionHistory)
    }

    function setTool(tool) {
        if (tool !== "" && root.enabledTools.indexOf(tool) === -1)
            return
        root.exitTextMode()
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

    function clearStrokes() {
        if (root.strokes.length > 0)
            root.commitStrokes([])
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

    // ── Text recognition and selection ───────────────────────────────────────

    // True when ocrLines, possibly none, are the text of the current selection.
    function ocrCurrent() {
        const r = root._ocrRegion
        return root.ocrState === "ready" && r !== null
               && r.x === root.selX && r.y === root.selY && r.w === root.selW && r.h === root.selH
    }

    // Called by the overlay that owns the selection before it grabs it. The
    // token goes to recognize() or failOcr() once the grab has returned.
    function beginOcr() {
        root._resetOcr()
        root._ocrRegion = { "x": root.selX, "y": root.selY, "w": root.selW, "h": root.selH }
        root.ocrState = "running"
        return root._ocrToken
    }

    // `path` is the selection as the overlay wrote it, `map` where it lies,
    // see Ocr.layout(). The file is removed once oar is done with it.
    function recognize(token, path, map) {
        if (token !== root._ocrToken) {
            Quickshell.execDetached(["rm", "-f", "--", path])
            return
        }
        const proc = ocrRunner.createObject(root, {
            "oar": Ocr.oarCommand(root.oarPath, root.oarArgs, Quickshell.env("HOME")),
            "picture": path
        })
        root._ocrProc = proc
        proc.recognized.connect((error, lines) => {
            proc.destroy()
            Quickshell.execDetached(["rm", "-f", "--", path])
            if (token !== root._ocrToken)
                return
            root._ocrProc = null
            if (error !== "") {
                root.failOcr(token, error)
                return
            }
            root.ocrLines = Ocr.layout(lines, map, ch => ocrMetrics.advanceWidth(ch))
            root.ocrState = "ready"
            root.ocrFinished("")
        })
        proc.running = true
    }

    // Esc while recognizing: stop, keep the selection.
    function cancelOcr() {
        root._resetOcr()
    }

    function failOcr(token, error) {
        if (token !== root._ocrToken)
            return
        root.ocrState = "failed"
        root._ocrRegion = null             // the next double-click tries again
        root.ocrFinished(error)
    }

    function _resetOcr() {
        root._ocrToken++
        if (root._ocrProc) {
            root._ocrProc.running = false  // what it still reports is dropped by the token
            root._ocrProc = null
        }
        root.ocrState = "idle"
        root.ocrLines = []
        root._ocrRegion = null
        root.exitTextMode()
    }

    function setTextSelection(anchor, focus) {
        root.textAnchor = anchor
        root.textFocus = focus
        root.textMode = true
    }

    // Text mode with nothing selected yet and every recognized line outlined.
    function markText() {
        root.textAnchor = null
        root.textFocus = null
        root.textMode = true
        root.textMarked = true
    }

    function exitTextMode() {
        root.textMode = false
        root.textMarked = false
        root.textAnchor = null
        root.textFocus = null
    }

    function selectAllText() {
        const lines = root.ocrLines
        if (lines.length > 0)
            root.setTextSelection({ "line": 0, "pos": 0 },
                                  { "line": lines.length - 1, "pos": lines[lines.length - 1].chars.length })
    }

    // Copies the selected text; the overlay stays. Returns the number of
    // characters copied, line breaks not counted.
    function copySelectedText() {
        if (!root.hasSelectedText)
            return 0
        const text = Ocr.textBetween(root.ocrLines, root.textAnchor, root.textFocus)
        const count = (text.replace(/\n/g, "").match(/[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]/g) || []).length
        if (count === 0)
            return 0
        DMSService.sendRequest("clipboard.copy", { "text": text }, resp => {
            if (resp && resp.error)
                console.warn("screenshotPlus: clipboard:", resp.error)
        })
        return count
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
            const file = `freeze-${name}-${stamp}.png`
            const path = root.runtimeDir + "/" + file
            Proc.runCommand("screenshotPlus.freeze." + name,
                            ["dms", "screenshot", "output", "-o", name, "--no-clipboard", "--no-notify",
                             "--dir", root.runtimeDir, "--filename", file, "--format", "png", "--json"],
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

    // Called by the overlay once the selection has been written to `path`;
    // `geom` is { screen, x, y, w, h }, the exported part of the selection in
    // that screen's coordinates. The session ends right away; conversion,
    // saving and the notification happen in finalize.sh, and the clipboard
    // is filled when it is done.
    function onExported(path, geom) {
        const intent = root.exportIntent
        const copy = intent === "copy" || (intent === "default" && root.copyToClipboard)
        const save = intent === "save" || (intent === "default" && root.saveToFile)
        const pin = intent === "pin" || (intent === "default" && root.pinToScreen)
        root._rememberRegion()
        root._endSession()
        // Before finalize.sh starts: the pin loads the file, finalize.sh deletes it.
        const pinId = pin ? root._addPin(path, geom) : 0
        root._finalize(path, copy, save, pinId)
    }

    // Runs finalize.sh on `path` and acts on the PNG it prints. The PNG is
    // removed once the clipboard has read it, unless it belongs to pin `pinId`.
    function _finalize(path, copy, save, pinId) {
        const body = !root.notify ? ""
                   : save ? (copy ? I18n.trFor("screenshotPlus", "Saved and copied to clipboard") : I18n.trFor("screenshotPlus", "Saved"))
                   : copy ? I18n.trFor("screenshotPlus", "Copied to clipboard") : ""
        const args = [path, save ? "1" : "", save ? root._saveDir() : "", body,
                      I18n.trFor("screenshotPlus", "Could not save to"), root._encoder, root.fileNamePattern]
        const job = "screenshotPlus.finalize" + (pinId ? ".pin" + pinId : "")
        Proc.runCommand(job, ["sh", root._finalizeScript, ...args], (stdout, code) => {
            const png = String(stdout).trim().split("\n").pop()
            if (code !== 0 || !png) {
                console.warn("screenshotPlus: finalize failed:", code, String(stdout).trim().slice(0, 200))
                return
            }
            if (pinId && root.pins.some(p => p.id === pinId))
                root._pinFiles = Object.assign({}, root._pinFiles, { [pinId]: png })
            else   // the clipboard and the notification daemon read the file asynchronously
                Quickshell.execDetached(["sh", "-c", 'sleep 10; rm -f -- "$1"', "sh", png])
            if (copy) {
                DMSService.sendRequest("clipboard.copyFile", { "filePath": png }, resp => {
                    if (resp && resp.error)
                        console.warn("screenshotPlus: clipboard:", resp.error)
                })
            }
        }, 0, 30000)
    }

    // "" when unset: the script falls back to <Pictures>/Screenshots.
    function _saveDir() {
        const d = root.saveDirectory.trim().replace(/\/+$/, "")
        return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d
    }

    // ── Pins ─────────────────────────────────────────────────────────────────

    function _addPin(src, g) {
        const id = root._nextPinId++
        root.pins = [...root.pins, { "id": id, "screen": g.screen, "x": g.x, "y": g.y, "w": g.w, "h": g.h, "src": src }]
        return id
    }

    function unpin(id) {
        const png = root._pinFiles[id]
        if (png) {
            const files = Object.assign({}, root._pinFiles)
            delete files[id]
            root._pinFiles = files
            Quickshell.execDetached(["rm", "-f", "--", png])
        }
        root.pins = root.pins.filter(p => p.id !== id)
    }

    function unpinAll() {
        for (const id in root._pinFiles)
            Quickshell.execDetached(["rm", "-f", "--", root._pinFiles[id]])
        root._pinFiles = {}
        root.pins = []
    }

    // Copy or save a pin: finalize.sh once more on its PNG, which stays in place.
    function exportPin(id, intent) {
        const png = root._pinFiles[id]
        if (!png) {
            console.warn("screenshotPlus: pin", id, "has no file yet")
            return
        }
        root._finalize(png, intent === "copy", intent === "save", id)
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

    Variants {
        model: root.pins
        delegate: PinnedImage {
            ctl: root
        }
    }

    // Character widths to spread the carets of a recognized line over its box.
    FontMetrics {
        id: ocrMetrics
        font.family: Theme.fontFamily
        font.pixelSize: 64
    }

    Component {
        id: ocrRunner
        OcrRunner {}
    }

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", "-m", "700", "--", root.runtimeDir])
        Proc.runCommand("screenshotPlus.encoder",
                        ["sh", "-c", "command -v ffmpeg >/dev/null && echo ffmpeg || { command -v magick >/dev/null && echo magick; }"],
                        (out, code) => { root._encoder = code === 0 ? String(out).trim() : "" }, 0, 5000)
    }

    Component.onDestruction: {
        if (root.active)
            root._endSession()
        root.unpinAll()
    }
}
