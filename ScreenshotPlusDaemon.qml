import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Screenshot+ daemon — orchestration and shared state.
//
// It owns everything that must be identical across monitors (the selection
// rectangle, the annotation strokes, the frozen frames) and hands it to
// CaptureOverlay, which draws one PanelWindow per screen.
//
// Coordinate convention: selection and strokes are stored in GLOBAL LOGICAL
// coordinates (the compositor's layout space, e.g. DP-1 = 0,0,1920,1080).
// Each overlay subtracts its own screen origin; export multiplies by the
// screen's scale factor to reach source pixels.
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
    // The default stays "cli" until that fix ships. Persist a choice with
    // `dms ipc call screenshotPlus setBackend screencopy`.
    property string backend: pluginData.backend === "screencopy" ? "screencopy" : "cli"

    // screenName -> "/tmp/dmsplus-freeze-<name>-<stamp>.png"
    property var freezes: ({})
    // screenName -> { x, y, width, height, scale, pixelWidth, pixelHeight }
    property var screenInfo: ({})

    // ── Selection (global logical coords) ────────────────────────────────────
    property bool hasSelection: false
    property real selX: 0
    property real selY: 0
    property real selW: 0
    property real selH: 0

    // ── Annotation ───────────────────────────────────────────────────────────
    property string activeTool: ""
    property color strokeColor: "#ff5252"
    property real strokeWidth: 3

    // Always replace these arrays wholesale — QML does not see in-place mutation.
    property var strokes: []
    property var undoneStrokes: []

    readonly property bool canUndo: strokes.length > 0
    readonly property bool canRedo: undoneStrokes.length > 0

    // Bumped to ask the overlay owning the selection to render and save.
    signal exportRequested

    property int _pendingGrabs: 0
    property var _grabAcc: ({})

    // True once the overlay actually has decoded pixels on screen.
    property bool frameShown: false
    property bool _pendingFinish: false

    // Timing instrumentation, surfaced through `status`.
    // grabMs  — capture() to the grab returning (when the dimmer appears)
    // readyMs — capture() to the frame being decoded and visible
    property double _t0: 0
    property int lastGrabMs: 0
    property int lastReadyMs: 0
    property string lastError: ""

    // ── Entry points ─────────────────────────────────────────────────────────

    function capture() {
        if (root.active || root.capturing) {
            console.log("screenshotPlus: capture already in progress")
            return
        }
        root._resetSession()
        root._t0 = Date.now()

        // Close popouts so they don't end up baked into the frozen frame.
        // Setting the singleton directly rather than shelling out to
        // `dms ipc call screenshot begin` saves a process spawn (~8ms) and,
        // more importantly, a round trip that used to block the grab.
        PopoutManager.screenshotActive = true

        root._collectScreenInfo()

        if (root.backend === "screencopy") {
            // ScreencopyView pulls the frame itself; geometry is all it needs.
            root.capturing = false
            root.active = true
            return
        }

        // Fire the grab BEFORE mapping the overlay. `dms screenshot` is served
        // by this same process, so mapping first makes the new layer's first
        // frame compete with the grab and roughly doubles its latency.
        root.capturing = true
        root._grabFreezes()

        // Now map. The overlay is fully transparent at this point — no dimmer,
        // no decorations — so it cannot contaminate the in-flight grab, but the
        // pointer is live immediately instead of a third of a second later.
        root.active = true
    }

    function _collectScreenInfo() {
        const screens = Quickshell.screens
        const info = {}

        for (let i = 0; i < screens.length; i++) {
            const sc = screens[i]
            info[sc.name] = {
                "x": sc.x,
                "y": sc.y,
                "width": sc.width,
                "height": sc.height,
                "scale": CompositorService.getScreenScale(sc)
            }
        }

        root.screenInfo = info
    }

    // Called by the overlay the moment it actually has pixels to show.
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
        if (!root.hasSelection || root.selW < 1 || root.selH < 1) {
            root._teardown()
            return
        }

        // The overlay now maps before the frame lands, so Enter can arrive
        // while the picture is still decoding — exporting here would save a
        // transparent rectangle. Queue it and let noteFrameReady() finish.
        if (root.capturing || !root.frameShown) {
            root._pendingFinish = true
            return
        }

        root.exportRequested()
    }

    // ── Annotation API (called from the overlay) ─────────────────────────────

    function pushStroke(stroke) {
        root.strokes = [...root.strokes, stroke]
        root.undoneStrokes = []
    }

    function undo() {
        if (root.strokes.length === 0)
            return
        const next = root.strokes.slice()
        const popped = next.pop()
        root.strokes = next
        root.undoneStrokes = [...root.undoneStrokes, popped]
    }

    function redo() {
        if (root.undoneStrokes.length === 0)
            return
        const next = root.undoneStrokes.slice()
        const popped = next.pop()
        root.undoneStrokes = next
        root.strokes = [...root.strokes, popped]
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
                            (stdout, exitCode) => root._onFreezeDone(name, "/tmp/" + fname,
                                                                    stdout, exitCode),
                            0, 15000)
        }
    }

    function _onFreezeDone(name, path, stdout, exitCode) {
        let ok = exitCode === 0
        if (ok) {
            try {
                ok = JSON.parse(stdout.trim()).status === "success"
            } catch (e) {
                console.warn("screenshotPlus: bad freeze JSON for", name, "-", stdout)
                ok = false
            }
        }

        if (!ok) {
            root.lastError = "grab " + name + " exit=" + exitCode
                    + " out=" + String(stdout).trim().slice(0, 200)
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

    // Called by the overlay once its offscreen canvas has written the PNG.
    function onExported(path) {
        if (!path) {
            root._teardown()
            return
        }

        DMSService.sendRequest("clipboard.copyFile", {
                                   "filePath": path
                               }, resp => {
                                   if (resp && resp.error)
                                       console.warn("screenshotPlus: clipboard failed -", resp.error)
                               })

        Quickshell.execDetached(["dms", "notify", "Screenshot+", "已复制到剪贴板",
                                 "--app", "Screenshot+", "--icon", "screenshot_region"])

        // Give the notification daemon time to read the file before it goes.
        Quickshell.execDetached(["sh", "-c",
                                 "sleep 10 && rm -f -- " + _shellQuote(path)])

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
        root.strokes = []
        root.undoneStrokes = []
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

        PopoutManager.screenshotActive = false

        for (const name in stale) {
            Quickshell.execDetached(["rm", "-f", "--", stale[name]])
        }
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

    // ── Wiring ───────────────────────────────────────────────────────────────

    CaptureOverlay {
        ctl: root
    }

    IpcHandler {
        // backend: "screencopy" (default, fast) or "cli" (fallback). Empty keeps
        // whatever is currently configured.
        // Quickshell rejects a call that supplies fewer arguments than the
        // signature declares, so the no-arg form has to be its own function —
        // this is the one you bind to a key.
        function capture(): string {
            root.capture()
            return "OK"
        }

        // One-off override; does not persist. See the `backend` property.
        function captureWith(backend: string): string {
            if (backend === "screencopy" || backend === "cli")
                root.backend = backend
            root.capture()
            return "OK"
        }

        // Persist the backend ("cli" | "screencopy") in the plugin settings.
        function setBackend(backend: string): string {
            if (backend !== "screencopy" && backend !== "cli")
                return "BAD_ARGS"
            root.savePluginData("backend", backend)
            root.backend = backend
            return "OK"
        }

        function cancel(): string {
            root.cancel()
            return "OK"
        }

        function status(): string {
            return JSON.stringify({
                                      "active": root.active,
                                      "capturing": root.capturing,
                                      "hasSelection": root.hasSelection,
                                      "strokes": root.strokes.length,
                                      "sel": [root.selX, root.selY, root.selW, root.selH],
                                      "backend": root.backend,
                                      "grabMs": root.lastGrabMs,
                                      "readyMs": root.lastReadyMs,
                                      "error": root.lastError
                                  })
        }

        // Set the selection without the mouse. Doubles as the scripting entry
        // point ("always grab this rectangle") and as the test hook.
        function select(x: string, y: string, w: string, h: string): string {
            if (!root.active)
                return "NOT_ACTIVE"
            const nx = parseFloat(x), ny = parseFloat(y)
            const nw = parseFloat(w), nh = parseFloat(h)
            if (![nx, ny, nw, nh].every(v => isFinite(v)) || nw < 1 || nh < 1)
                return "BAD_ARGS"
            root.setSelection(nx, ny, nw, nh)
            return "OK"
        }

        function finish(): string {
            if (!root.active)
                return "NOT_ACTIVE"
            root.finish()
            return "OK"
        }

        // Self-test: drop a rectangle and a diagonal inside the selection so the
        // export path can be verified end to end without a human holding a mouse.
        function testStroke(): string {
            if (!root.hasSelection)
                return "NO_SELECTION"
            const x = root.selX, y = root.selY, w = root.selW, h = root.selH
            root.pushStroke({
                                "tool": "rect",
                                "color": "#ff5252",
                                "width": 4,
                                "points": [{
                                        "x": x + w * 0.2,
                                        "y": y + h * 0.2
                                    }, {
                                        "x": x + w * 0.8,
                                        "y": y + h * 0.8
                                    }]
                            })
            root.pushStroke({
                                "tool": "pen",
                                "color": "#4caf50",
                                "width": 4,
                                "points": [{
                                        "x": x + w * 0.2,
                                        "y": y + h * 0.8
                                    }, {
                                        "x": x + w * 0.5,
                                        "y": y + h * 0.5
                                    }, {
                                        "x": x + w * 0.8,
                                        "y": y + h * 0.2
                                    }]
                            })
            return "OK"
        }

        target: "screenshotPlus"
        enabled: true
    }

    Component.onCompleted: {
        if (pluginService && pluginId)
            pluginService.pluginInstances[pluginId] = root
    }

    Component.onDestruction: {
        if (root.active)
            root._teardown()
        if (pluginService && pluginId && pluginService.pluginInstances[pluginId] === root)
            delete pluginService.pluginInstances[pluginId]
    }
}
