.pragma library

// Plugin settings: the single source of defaults. The settings page and the
// daemon both read from here, so the behaviour before the settings page has
// ever been opened is identical to the page's initial state.

var DEFAULTS = {
    defaultColor: "#ff5252",
    defaultWidthPreset: "M",     // S | M | L | XL, see Tools.js
    copyToClipboard: true,
    saveToFile: false,
    saveDirectory: "",           // "" = <Pictures>/Screenshots, resolved at runtime
    notify: true,
    backend: "cli"               // cli | screencopy
}

function toolEnabledKey(id) {
    return "tool_" + id + "_enabled"
}

function read(pluginData, key) {
    var v = pluginData ? pluginData[key] : undefined
    return (v === undefined || v === null) ? DEFAULTS[key] : v
}

// Tools default to enabled; only an explicit false hides one.
function toolEnabled(pluginData, id) {
    return !pluginData || pluginData[toolEnabledKey(id)] !== false
}
