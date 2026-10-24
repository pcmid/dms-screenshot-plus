import QtQuick
import Quickshell.Io
import qs.Common
import "lib/Ocr.js" as Ocr

// One run of oar on one picture. recognized() comes once the process has
// exited and both of its streams are read, with the parsed lines, or with
// an error message for the user.
Process {
    id: proc

    property var oar: []               // Ocr.oarCommand()
    property string picture: ""
    property int timeout: 30000
    property bool _timedOut: false
    property int _left: 3              // exit plus two streams
    property int _code: -1
    property string _out: ""
    property string _err: ""

    signal recognized(string error, var lines)   // lines: Ocr.parse() lines

    // Through sh, so that a wrong path ends in a message on stderr rather
    // than in a process that never starts; exec leaves signals to oar.
    command: ["sh", "-c", "exec \"$@\"", "sh", ...proc.oar, proc.picture]

    function _step() {
        if (--proc._left > 0)
            return
        if (proc._timedOut) {
            proc.recognized(I18n.trFor("screenshotPlus", "timed out"), [])
            return
        }
        if (proc._code !== 0) {
            const err = proc._err.split("\n").map(s => s.trim()).filter(s => s !== "")
            proc.recognized(err.length > 0 ? err[0] : I18n.trFor("screenshotPlus", "exit code %1").arg(proc._code), [])
            return
        }
        const r = Ocr.parse(proc._out)
        if (r.error)
            proc.recognized(I18n.trFor("screenshotPlus", "could not read oar's output"), [])
        else
            proc.recognized("", r.lines)
    }

    stdout: StdioCollector {
        onStreamFinished: {
            proc._out = text
            proc._step()
        }
    }
    stderr: StdioCollector {
        onStreamFinished: {
            proc._err = text
            proc._step()
        }
    }
    onExited: exitCode => {
        proc._code = exitCode
        proc._step()
    }

    property Timer _timer: Timer {
        interval: proc.timeout
        running: proc.running
        onTriggered: {
            proc._timedOut = true
            proc.running = false
        }
    }
}
