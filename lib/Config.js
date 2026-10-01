.pragma library

// Setting defaults, shared by the daemon and the settings page so that both
// agree before the page has ever been opened.

var DEFAULTS = {
    defaultColor: "#ff5252",
    defaultWidthPreset: "M",     // S | M | L | XL, see Tools.js
    copyToClipboard: true,
    saveToFile: false,
    pinToScreen: false,
    saveDirectory: "",           // "" = <Pictures>/Screenshots
    fileNamePattern: "",         // "" = screenshot-%Y%m%d-%H%M%S, date(1) format
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

// Tools are enabled unless explicitly switched off.
function toolEnabled(pluginData, id) {
    return !pluginData || pluginData[toolEnabledKey(id)] !== false
}
