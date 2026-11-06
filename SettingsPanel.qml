import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hoverview settings card. It reads the widget's shell.json entry through
// the shell's IPC and writes with `omarchy bar set`, so any bar widget can
// host it: load this file, inject `bar` and `anchorItem`, call open/close/toggle.
Panel {
  id: root
  moduleName: "io.github.abdulrahmanhr.hoverview"
  manageIpc: false

  property Item anchorItem: null

  readonly property string pluginId: "io.github.abdulrahmanhr.hoverview"
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string themeDir: Quickshell.env("HOME") + "/.local/state/omarchy/current"

  // Current values with defaults filled in, coerced and clamped exactly like
  // BarWidget.qml. Edits land here first, then in `pending` until written.
  property var values: root.normalize(null)
  property var pending: ({})
  property bool inBar: true
  // Omarchy's own workspaces widget, which Hoverview replaces, is on the bar
  property bool builtinOnBar: false
  property bool readQueued: false
  // Bumped per write; a read that began before a write is stale
  property int writeGen: 0
  property string errorText: ""
  property string themeText: ""
  // Overview shortcut recording: while on, the next key press is captured
  property bool recording: false
  // Shown under the shortcut row: a conflict with another bind, or a hint
  property string shortcutWarning: ""
  // Set by BarWidget: why the bind could not be registered, if it could not
  property string bindError: ""

  readonly property bool busy: writeProc.running || writeDebounce.running || Object.keys(root.pending).length > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real labelWidth: Style.space(112)
  readonly property real disabledOpacity: 0.4

  // Cursor model shared by keyboard and mouse, as in the first-party panels.
  // A section is a setting key, plus "reset"; disabled rows are skipped.
  property string focusSection: "persistentWorkspaces"
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool confirmOpen: false

  readonly property var sections: {
    var v = root.values || ({})
    var list = root.builtinOnBar ? ["replaceBuiltin"] : []
    list.push("persistentWorkspaces", "labelVerticalOffset", "showLayoutShape", "alwaysShowLayoutShapes",
      "cycleLayoutOnClick", "preview")
    if (v.preview) {
      list.push("hoverDelayMs", "previewWidth", "livePreview", "showWindowList")
      if (v.showWindowList) list.push("maxListedWindows")
      list.push("highlightLastFocused", "peekOnHover")
      if (v.peekOnHover) list.push("peekDelayMs")
    }
    list.push("overviewShortcut", "colorSecondaryMonitor")
    if (v.colorSecondaryMonitor) {
      for (var m = 0; m < root.otherMonitors.length; m++) list.push("monitorColor:" + root.otherMonitors[m].name)
    }
    list.push("reset")
    return list
  }

  // Keys, defaults and ranges; keep in sync with BarWidget.qml and manifest.json
  function specList() {
    return [
      { key: "persistentWorkspaces", type: "int", fallback: 0, min: 0, max: 10, step: 1 },
      { key: "labelVerticalOffset", type: "number", fallback: 0, min: -10, max: 10, step: 0.5 },
      { key: "showLayoutShape", type: "bool", fallback: true },
      { key: "alwaysShowLayoutShapes", type: "bool", fallback: false },
      { key: "cycleLayoutOnClick", type: "bool", fallback: true },
      { key: "colorSecondaryMonitor", type: "bool", fallback: true },
      { key: "secondaryMonitorColor", type: "color", fallback: "" },
      { key: "monitorColors", type: "map", fallback: "" },
      { key: "overviewShortcut", type: "shortcut", fallback: "SUPER + ALT + grave" },
      { key: "preview", type: "bool", fallback: true },
      { key: "hoverDelayMs", type: "int", fallback: 220, min: 0, max: 2000, step: 10 },
      { key: "previewWidth", type: "int", fallback: 420, min: 240, max: 800, step: 10 },
      { key: "livePreview", type: "bool", fallback: true },
      { key: "showWindowList", type: "bool", fallback: true },
      { key: "maxListedWindows", type: "int", fallback: 6, min: 1, max: 20, step: 1 },
      { key: "highlightLastFocused", type: "bool", fallback: true },
      { key: "peekOnHover", type: "bool", fallback: true },
      { key: "peekDelayMs", type: "int", fallback: 180, min: 0, max: 2000, step: 10 }
    ]
  }

  function specFor(key) {
    var list = root.specList()
    for (var i = 0; i < list.length; i++) {
      if (list[i].key === key) return list[i]
    }
    return null
  }

  function coerce(spec, v) {
    if (spec.type === "bool") {
      if (typeof v === "boolean") return v
      if (v === 1 || v === 0) return v === 1
      if (typeof v === "string") {
        var s = v.trim().toLowerCase()
        if (s === "true" || s === "on" || s === "yes" || s === "1") return true
        if (s === "false" || s === "off" || s === "no" || s === "0") return false
      }
      return spec.fallback
    }
    if (spec.type === "shortcut") {
      if (v === undefined || v === null) return spec.fallback
      var combo = String(v).trim()
      return combo === "" || /^[A-Za-z0-9_:+ ]+$/.test(combo) ? combo : spec.fallback
    }
    if (spec.type === "map") return root.mapText(root.parseMap(v))
    if (spec.type === "color") {
      var c = v === undefined || v === null ? "" : String(v).trim()
      return /^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/.test(c) ? c : ""
    }
    var n = NaN
    if (typeof v === "number") n = v
    else if (typeof v === "string" && v.trim() !== "") n = Number(v.trim())
    if (!isFinite(n)) return spec.fallback
    n = Math.min(spec.max, Math.max(spec.min, n))
    return spec.type === "int" ? Math.round(n) : n
  }

  function normalize(entry) {
    var e = entry && typeof entry === "object" ? entry : {}
    var list = root.specList()
    var out = {}
    for (var i = 0; i < list.length; i++) out[list[i].key] = root.coerce(list[i], e[list[i].key])
    return out
  }

  // ---------------------------------------------------------------- reading

  function findEntry(config) {
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout || typeof layout !== "object") return null
    var regions = ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
    for (var r = 0; r < regions.length; r++) {
      var list = layout[regions[r]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        if (entry === root.pluginId) return {}
        if (entry && typeof entry === "object" && entry.id === root.pluginId) return entry
      }
    }
    return null
  }

  function entryId(entry) {
    return typeof entry === "string" ? entry : (entry && typeof entry === "object" ? String(entry.id || "") : "")
  }

  function hasBuiltinWorkspaces(config) {
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout || typeof layout !== "object") return false
    for (var section in layout) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        if (root.entryId(list[i]) === "omarchy.workspaces") return true
      }
    }
    return false
  }

  // Reads never write. Unsaved edits stay on top of what was read.
  function applyConfig(text) {
    var config = null
    try {
      config = JSON.parse(String(text || ""))
    } catch (e) {
      return
    }
    if (readProc.writeGen !== root.writeGen) {
      root.readQueued = true
      return
    }
    var entry = root.findEntry(config)
    root.inBar = entry !== null
    root.builtinOnBar = root.hasBuiltinWorkspaces(config)
    var next = root.normalize(entry)
    if (writeProc.running && writeProc.key !== "") next[writeProc.key] = writeProc.value
    for (var key in root.pending) next[key] = root.pending[key]
    root.values = next
  }

  function refresh() {
    if (readProc.running || writeProc.running) {
      root.readQueued = true
      return
    }
    root.readQueued = false
    readProc.writeGen = root.writeGen
    readProc.running = true
  }

  Process {
    id: readProc
    property int writeGen: 0
    command: ["omarchy-shell", "shell", "listShellConfig"]
    stdout: StdioCollector {
      id: readOut
      waitForEnd: true
      onStreamFinished: root.applyConfig(readOut.text)
    }
    onRunningChanged: {
      if (!running && root.readQueued) Qt.callLater(root.refresh)
    }
  }

  // Picks up edits made elsewhere (CLI, editor) while the card is open
  FileView {
    id: shellConfigFile
    path: root.opened ? root.shellConfigPath : ""
    watchChanges: true
    printErrors: false
    atomicWrites: true
    blockLoading: true
    onFileChanged: {
      reload()
      root.refresh()
    }
  }

  // ------------------------------------------------- replacing the built-in

  // A widget plugin may only change its own entry through the shell, and
  // `omarchy bar` has no way to take a widget off, so the swap edits
  // shell.json itself: Hoverview takes the built-in's place, keeping its own
  // settings, and the built-in leaves every section. The shell reloads the
  // file on save. Only ever run from the button, never on its own.
  function replaceBuiltin() {
    var config = null
    try {
      config = JSON.parse(String(shellConfigFile.text() || ""))
    } catch (e) {
      root.errorText = "Could not read shell.json"
      return
    }
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout || typeof layout !== "object") {
      root.errorText = "shell.json has no bar layout"
      return
    }

    var own = null
    var section
    for (section in layout) {
      if (!Array.isArray(layout[section])) continue
      layout[section] = layout[section].filter(function(entry) {
        if (root.entryId(entry) !== root.pluginId) return true
        if (own === null) own = entry
        return false
      })
    }
    if (own === null) own = { id: root.pluginId }

    var placed = false
    for (section in layout) {
      if (!Array.isArray(layout[section])) continue
      var next = []
      for (var i = 0; i < layout[section].length; i++) {
        var entry = layout[section][i]
        if (root.entryId(entry) !== "omarchy.workspaces") next.push(entry)
        else if (!placed) {
          next.push(own)
          placed = true
        }
      }
      layout[section] = next
    }
    if (!placed) return

    shellConfigFile.setText(JSON.stringify(config, null, 2) + "\n")
    root.builtinOnBar = false
    root.errorText = ""
  }

  // ---------------------------------------------------------------- writing

  // Values show at once; the write waits for a short pause so sliders and
  // steppers don't spawn a process per step.
  function setValue(key, value, immediate) {
    var next = Object.assign({}, root.values)
    next[key] = value
    root.values = next
    var queued = Object.assign({}, root.pending)
    queued[key] = value
    root.pending = queued
    if (immediate) {
      writeDebounce.stop()
      root.flush()
    } else {
      writeDebounce.restart()
    }
  }

  // One `omarchy bar set` at a time; the config is read back after the last
  function flush() {
    if (writeProc.running) return
    var keys = Object.keys(root.pending)
    if (keys.length === 0) {
      root.refresh()
      return
    }
    var key = keys[0]
    var queued = Object.assign({}, root.pending)
    var value = queued[key]
    delete queued[key]
    root.pending = queued
    writeProc.key = key
    writeProc.value = value
    writeProc.command = ["omarchy", "bar", "set", root.pluginId, key, JSON.stringify(value), "--json"]
    root.writeGen++
    writeProc.running = true
  }

  Timer {
    id: writeDebounce
    interval: 300
    repeat: false
    onTriggered: root.flush()
  }

  Process {
    id: writeProc
    property string key: ""
    property var value: null
    property int exitCode: 0
    stderr: StdioCollector {
      id: writeErr
      waitForEnd: true
    }
    onExited: function(exitCode) { writeProc.exitCode = exitCode }
    onRunningChanged: {
      if (!running) Qt.callLater(root.writeFinished)
    }
  }

  function writeFinished() {
    if (writeProc.exitCode === 0) {
      root.errorText = ""
    } else {
      var lines = String(writeErr.text || "").trim().split("\n")
      var last = lines[lines.length - 1].trim()
      root.errorText = last !== "" ? last : "Could not save " + writeProc.key
    }
    root.flush()
  }

  function flip(key) {
    root.setValue(key, !root.values[key], true)
  }

  function snapValue(key, raw) {
    var spec = root.specFor(key)
    var v = Math.round(Number(raw) / spec.step) * spec.step
    v = Math.max(spec.min, Math.min(spec.max, v))
    return Math.round(v * 100) / 100
  }

  function stepValue(key, direction) {
    var spec = root.specFor(key)
    var next = root.snapValue(key, root.values[key] + direction * spec.step)
    if (next !== root.values[key]) root.setValue(key, next)
  }

  function resetDefaults() {
    root.confirmOpen = false
    root.shortcutWarning = ""
    var list = root.specList()
    var next = Object.assign({}, root.values)
    var queued = Object.assign({}, root.pending)
    for (var i = 0; i < list.length; i++) {
      next[list[i].key] = list[i].fallback
      queued[list[i].key] = list[i].fallback
    }
    root.values = next
    root.pending = queued
    writeDebounce.stop()
    root.flush()
  }

  function openConfirm() {
    resetConfirm.selectedIndex = 0
    root.confirmOpen = true
  }

  // ------------------------------------------------------------ theme colors

  FileView {
    id: themeColorsFile
    path: root.themeDir + "/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeText = text()
    onLoadFailed: root.themeText = ""
    onFileChanged: reload()
  }

  // Theme switches replace the theme directory, which drops the watch above
  FileView {
    path: root.themeDir + "/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: themeColorsFile.reload()
  }

  function themeColor(name) {
    var match = root.themeText.match(new RegExp("^\\s*" + name + "\\s*=\\s*[\"']?(#[0-9A-Fa-f]{6})", "m"))
    return match ? match[1] : ""
  }

  // ------------------------------------------------- per-monitor colors

  // Connected non-primary monitors, by id
  readonly property var otherMonitors: {
    var out = []
    var values = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < values.length; i++) {
      var mon = values[i]
      if (mon.id <= 0) continue
      var ipc = mon.lastIpcObject
      out.push({ name: String(mon.name), id: mon.id, description: ipc && ipc.description ? String(ipc.description) : "" })
    }
    out.sort(function(a, b) { return a.id - b.id })
    return out
  }

  // monitorColors is a JSON string (the schema has no object type), or an object
  function parseMap(v) {
    var obj = v
    if (typeof v === "string") {
      try { obj = JSON.parse(v) } catch (e) { obj = null }
    }
    var out = {}
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return out
    for (var name in obj) {
      var c = String(obj[name]).trim()
      if (/^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/.test(c)) out[name] = c
    }
    return out
  }

  function mapText(map) {
    return Object.keys(map).length > 0 ? JSON.stringify(map) : ""
  }

  function isMonitorSection(section) {
    return String(section).indexOf("monitorColor:") === 0
  }

  function monitorOf(section) {
    return String(section).slice("monitorColor:".length)
  }

  // What "" resolves to for a monitor in BarWidget.qml: the legacy single
  // color if set, else a distinct theme color by order among other monitors
  function defaultColorFor(name) {
    if (root.values.secondaryMonitorColor) return root.values.secondaryMonitorColor
    var groups = [["magenta", "purple", "orange", "yellow"], ["cyan"], ["yellow"], ["green"], ["blue"], ["orange"], ["red"]]
    var palette = []
    var seen = {}
    for (var i = 0; i < groups.length; i++) {
      for (var j = 0; j < groups[i].length; j++) {
        var c = root.themeColor(groups[i][j])
        if (!c) continue
        if (!seen[c.toLowerCase()]) {
          seen[c.toLowerCase()] = true
          palette.push(c)
        }
        break
      }
    }
    if (palette.length === 0) return "#b587a0"
    var at = 0
    for (var k = 0; k < root.otherMonitors.length; k++) {
      if (root.otherMonitors[k].name === name) { at = k; break }
    }
    return palette[at % palette.length]
  }

  function colorOptionsFor(name) {
    var list = [{ value: "", color: root.defaultColorFor(name), label: "Theme", hint: "Default for this monitor" }]
    var seen = {}
    var names = ["red", "orange", "yellow", "green", "cyan", "blue", "magenta", "accent"]
    for (var i = 0; i < names.length; i++) {
      var c = root.themeColor(names[i])
      if (!c || seen[c.toLowerCase()]) continue
      seen[c.toLowerCase()] = true
      list.push({ value: c, color: c, label: "", hint: names[i].charAt(0).toUpperCase() + names[i].slice(1) + "  " + c })
    }
    var current = root.parseMap(root.values.monitorColors)[name] || ""
    if (current !== "" && !seen[current.toLowerCase()]) list.push({ value: current, color: current, label: "", hint: "Custom  " + current })
    return list
  }

  function colorIndexFor(name) {
    var current = String(root.parseMap(root.values.monitorColors)[name] || "").toLowerCase()
    var options = root.colorOptionsFor(name)
    for (var i = 0; i < options.length; i++) {
      if (options[i].value.toLowerCase() === current) return i
    }
    return 0
  }

  function chooseMonitorColor(name, index) {
    var option = root.colorOptionsFor(name)[index]
    if (!option) return
    root.selectedIndex = index
    var map = root.parseMap(root.values.monitorColors)
    if (option.value === "") delete map[name]
    else map[name] = option.value
    var text = root.mapText(map)
    if (text !== root.values.monitorColors) root.setValue("monitorColors", text, true)
  }

  // ------------------------------------------------------ overview shortcut

  // xkb keycodes (evdev + 8) to Hyprland key names. Letters are named from the
  // key itself, so other layouts get the letter they print.
  readonly property var scanNames: ({
    9: "ESCAPE", 10: "1", 11: "2", 12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
    20: "minus", 21: "equal", 22: "BACKSPACE", 23: "TAB", 34: "bracketleft", 35: "bracketright", 36: "RETURN",
    47: "semicolon", 48: "apostrophe", 49: "grave", 51: "backslash", 59: "comma", 60: "period", 61: "slash",
    65: "SPACE", 67: "F1", 68: "F2", 69: "F3", 70: "F4", 71: "F5", 72: "F6", 73: "F7", 74: "F8", 75: "F9",
    76: "F10", 95: "F11", 96: "F12", 111: "UP", 113: "LEFT", 114: "RIGHT", 116: "DOWN",
    191: "F13", 192: "F14", 193: "F15", 194: "F16", 195: "F17", 196: "F18", 197: "F19", 198: "F20",
    199: "F21", 200: "F22", 201: "F23", 202: "F24"
  })

  function keyNameFor(event) {
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(65 + k - Qt.Key_A)
    var sc = event.nativeScanCode
    if (!sc) return ""
    return root.scanNames[sc] || "code:" + sc
  }

  function isModifierKey(k) {
    return k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_Meta
      || k === Qt.Key_Super_L || k === Qt.Key_Super_R || k === Qt.Key_AltGr || k === Qt.Key_CapsLock
      || k === Qt.Key_NumLock || k === Qt.Key_ScrollLock || k === Qt.Key_Hyper_L || k === Qt.Key_Hyper_R
      || k === Qt.Key_Mode_switch
  }

  function startRecording() {
    root.recording = true
    root.shortcutWarning = ""
    Qt.callLater(function() { if (root.recording) recorder.forceActiveFocus() })
  }

  function stopRecording() {
    root.recording = false
    keyCatcher.forceActiveFocus()
  }

  // Combos Hyprland already binds never get here: it runs them instead
  function recordKey(event) {
    event.accepted = true
    if (event.isAutoRepeat) return
    var k = event.key
    var m = event.modifiers
    var held = (m & Qt.MetaModifier) || (m & Qt.ControlModifier) || (m & Qt.AltModifier)
    if (root.isModifierKey(k)) return
    if (k === Qt.Key_Escape && m === Qt.NoModifier) {
      root.stopRecording()
      return
    }
    if (k === Qt.Key_Backspace && !held) {
      root.stopRecording()
      root.shortcutWarning = ""
      if (root.values.overviewShortcut !== "") root.setValue("overviewShortcut", "", true)
      return
    }
    if (!held) {
      root.shortcutWarning = "Include Super, Ctrl or Alt"
      return
    }
    var name = root.keyNameFor(event)
    if (name === "") {
      root.shortcutWarning = "Could not read that key"
      return
    }
    var parts = []
    var mask = 0
    if (m & Qt.MetaModifier) { parts.push("SUPER"); mask |= 64 }
    if (m & Qt.ControlModifier) { parts.push("CTRL"); mask |= 4 }
    if (m & Qt.ShiftModifier) { parts.push("SHIFT"); mask |= 1 }
    if (m & Qt.AltModifier) { parts.push("ALT"); mask |= 8 }
    parts.push(name)
    root.stopRecording()
    root.shortcutWarning = ""
    root.setValue("overviewShortcut", parts.join(" + "), true)
    root.checkMask = mask
    root.checkKey = name
    if (!bindsProc.running) bindsProc.running = true
  }

  property int checkMask: 0
  property string checkKey: ""

  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      id: bindsOut
      waitForEnd: true
      onStreamFinished: root.checkConflicts(bindsOut.text)
    }
  }

  // Another bind on the same modifiers and key; ours are not counted
  function checkConflicts(text) {
    var list = []
    try { list = JSON.parse(String(text || "[]")) } catch (e) { return }
    var found = []
    var wantCode = root.checkKey.indexOf("code:") === 0 ? Number(root.checkKey.slice(5)) : -1
    for (var i = 0; i < list.length; i++) {
      var b = list[i]
      var arg = String(b.arg || "")
      // Our own bind, current or switched off (Hyprland keeps disabled binds
      // in the list, and reports Lua binds by handle number, not by event),
      // is known by the description BarWidget.bindLua gives it.
      if (String(b.description || "") === "Workspace overview (Hoverview)" || arg.indexOf("hoverview overview") !== -1) continue
      if (b.mouse || b.modmask !== root.checkMask) continue
      var sameKey = String(b.key || "").toLowerCase() === root.checkKey.toLowerCase()
        || (wantCode >= 0 && Number(b.keycode) === wantCode)
      if (!sameKey) continue
      var label = String(b.description || "")
      if (label === "") label = String(b.dispatcher || "") + (arg !== "" ? " " + arg : "")
      if (found.indexOf(label) === -1) found.push(label)
    }
    root.shortcutWarning = found.length > 0 ? "Also used by: " + found.slice(0, 2).join(", ") + (found.length > 2 ? " and more" : "") : ""
  }

  // ------------------------------------------------------------------ cursor

  function cursorAt(section, index) {
    return root.cursorActive && root.focusSection === section
      && (index === undefined || root.selectedIndex === index)
  }

  function setCursor(section, index) {
    root.cursorActive = true
    root.focusSection = section
    root.selectedIndex = index || 0
  }

  function landingIndex(section) {
    return root.isMonitorSection(section) ? root.colorIndexFor(root.monitorOf(section)) : 0
  }

  // A row that gets disabled hands the cursor to the toggle above it
  function clampCursor() {
    var list = root.sections
    if (list.indexOf(root.focusSection) !== -1) return
    var order = ["replaceBuiltin", "persistentWorkspaces", "labelVerticalOffset", "showLayoutShape",
      "alwaysShowLayoutShapes", "cycleLayoutOnClick", "preview", "hoverDelayMs", "previewWidth",
      "livePreview", "showWindowList", "maxListedWindows", "highlightLastFocused", "peekOnHover",
      "peekDelayMs", "overviewShortcut", "colorSecondaryMonitor", "reset"]
    var from = root.isMonitorSection(root.focusSection) ? "colorSecondaryMonitor" : root.focusSection
    for (var i = order.indexOf(from); i >= 0; i--) {
      if (list.indexOf(order[i]) !== -1) {
        root.focusSection = order[i]
        root.selectedIndex = root.landingIndex(order[i])
        return
      }
    }
    root.focusSection = list[0]
    root.selectedIndex = 0
  }

  function moveCursor(dx, dy) {
    root.clampCursor()
    var list = root.sections
    if (dy !== 0) {
      var at = list.indexOf(root.focusSection)
      var next = Math.max(0, Math.min(list.length - 1, at + dy))
      if (next !== at) root.setCursor(list[next], root.landingIndex(list[next]))
      return
    }
    if (dx === 0) return
    if (root.isMonitorSection(root.focusSection)) {
      var count = root.colorOptionsFor(root.monitorOf(root.focusSection)).length
      root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + dx))
      return
    }
    var spec = root.specFor(root.focusSection)
    if (!spec) return
    if (spec.type === "int" || spec.type === "number") root.stepValue(spec.key, dx)
  }

  function activateCursor() {
    root.clampCursor()
    var key = root.focusSection
    if (key === "reset") root.openConfirm()
    else if (key === "replaceBuiltin") root.replaceBuiltin()
    else if (key === "overviewShortcut") root.startRecording()
    else if (root.isMonitorSection(key)) root.chooseMonitorColor(root.monitorOf(key), root.selectedIndex)
    else if (root.specFor(key) && root.specFor(key).type === "bool") root.flip(key)
  }

  function scrollIntoView(item) {
    if (!item) return
    Qt.callLater(function() {
      if (!item || !flick) return
      var margin = Style.space(6)
      var top = item.mapToItem(flick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
      else if (bottom > flick.contentY + flick.height - margin) flick.contentY = Math.min(maxY, bottom + margin - flick.height)
    })
  }

  function workspacesText(n) {
    if (n <= 0) return "Off"
    return n === 1 ? "1" : "1\u2013" + n
  }

  function offsetText(v) {
    if (v === 0) return "0"
    return (v > 0 ? "+" : "\u2212") + String(Math.abs(v))
  }

  onSectionsChanged: root.clampCursor()

  // Every open re-reads the config; the cursor stays hidden until hover or a key
  onOpenedChanged: {
    root.confirmOpen = false
    root.recording = false
    root.shortcutWarning = ""
    if (!root.opened) {
      if (writeDebounce.running) {
        writeDebounce.stop()
        root.flush()
      }
      return
    }
    root.cursorActive = false
    root.focusSection = "persistentWorkspaces"
    root.selectedIndex = 0
    root.errorText = ""
    flick.contentY = 0
    root.refresh()
  }

  Component.onCompleted: root.refresh()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While recording, the recorder below takes every key
      blocked: root.recording
      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0) resetConfirm.selectedIndex = resetConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) {
          root.cursorActive = true
          root.clampCursor()
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.confirmOpen) {
          if (resetConfirm.selectedIndex === 1) root.resetDefaults()
          else root.confirmOpen = false
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.confirmOpen) root.confirmOpen = false
        else root.close()
      }

      Item {
        id: recorder
        width: 0
        height: 0
        Keys.onPressed: function(event) { root.recordKey(event) }
        onActiveFocusChanged: if (!recorder.activeFocus && root.recording) root.stopRecording()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: column
          // A 1px inset keeps the outer borders of the rows inside the clip
          x: 1
          width: flick.width - 2
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Hoverview"
            meta: root.busy ? "Saving" : (root.inBar ? "Settings" : "Not on the bar")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uDB84\uDFB4"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Built-in still on the bar ----------
          // A fresh install lands next to Omarchy's own workspaces, which then
          // show twice and keep the layout refresh to themselves.
          Item {
            visible: root.builtinOnBar
            width: parent.width
            implicitHeight: visible ? Math.max(builtinText.implicitHeight, replaceButton.implicitHeight) : 0

            Text {
              id: builtinText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: replaceButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "Omarchy's own workspaces are also on the bar"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              id: replaceButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Replace them"
              iconText: "\uDB81\uDCE1"
              iconSize: Style.font.body
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.lg
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              hasCursor: root.cursorAt("replaceBuiltin")
              onClicked: root.replaceBuiltin()
              tooltipText: "Put Hoverview where Omarchy's workspaces are and take those off the bar"
              onHovered: function(isHovered) {
                if (isHovered) root.setCursor("replaceBuiltin", 0)
              }
            }
          }

          // ---------- Workspaces ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "WORKSPACES"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(2)
            }

            StepperRow {
              key: "persistentWorkspaces"
              label: "Always show"
              hint: "Keep this monitor's workspaces 1 to N on the bar, even when empty"
              valueText: root.workspacesText(root.values.persistentWorkspaces)
            }

            StepperRow {
              key: "labelVerticalOffset"
              label: "Label offset"
              hint: "Nudge the labels up or down for fonts that sit off-center"
              valueText: root.offsetText(root.values.labelVerticalOffset)
            }

            SwitchRow {
              key: "showLayoutShape"
              label: "Layout shape"
              hint: "Draw the active number on its layout shape: square, circle or triangle"
            }

            SwitchRow {
              key: "alwaysShowLayoutShapes"
              label: "Shapes everywhere"
              hint: "Draw every workspace's number on a faint layout shape, not just the active one"
            }

            SwitchRow {
              key: "cycleLayoutOnClick"
              label: "Click to cycle layout"
              hint: "Click the active workspace to cycle tiling, scrolling and floating, like Super + L"
            }
          }

          // ---------- Hover card ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

            GroupHeader {
              key: "preview"
              title: "HOVER CARD"
              hint: "Show a preview when you hover a workspace number"
            }

            SliderRow {
              key: "hoverDelayMs"
              label: "Hover delay"
              hint: "How long to hover before the card opens"
              unit: "ms"
              rowEnabled: root.values.preview
            }

            SliderRow {
              key: "previewWidth"
              label: "Preview width"
              hint: "Width of the mini screen; its height follows the monitor"
              unit: "px"
              rowEnabled: root.values.preview
            }

            SwitchRow {
              key: "livePreview"
              label: "Live capture"
              hint: "Live window contents; off draws app icons and names"
              rowEnabled: root.values.preview
            }

            SwitchRow {
              key: "showWindowList"
              label: "Window list"
              hint: "List the workspace's windows under the preview"
              rowEnabled: root.values.preview
            }

            StepperRow {
              key: "maxListedWindows"
              label: "Listed windows"
              hint: "Rows before the list says \"+ N more windows\""
              valueText: String(root.values.maxListedWindows)
              rowEnabled: root.values.preview && root.values.showWindowList
            }

            SwitchRow {
              key: "highlightLastFocused"
              label: "Highlight last used"
              hint: "Mark the window you used last; off marks only the focused one"
              rowEnabled: root.values.preview
            }
          }

          // ---------- Peek ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

            GroupHeader {
              key: "peekOnHover"
              title: "PEEK"
              hint: root.values.preview
                ? "Rest on the preview to switch there until you move away"
                : "Peek needs the hover card"
              rowEnabled: root.values.preview
            }

            SliderRow {
              key: "peekDelayMs"
              label: "Peek delay"
              hint: "How long to rest on the preview before peeking"
              unit: "ms"
              rowEnabled: root.values.preview && root.values.peekOnHover
            }
          }

          // ---------- Overview ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "OVERVIEW"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(2)
            }

            ShortcutRow {}

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              text: root.recording ? "Press a shortcut\u2026 (Esc cancel, Backspace off)"
                : (root.shortcutWarning !== "" ? root.shortcutWarning : root.bindError)
              color: root.recording ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Second monitor ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            GroupHeader {
              key: "colorSecondaryMonitor"
              title: "OTHER MONITORS"
              hint: "Mark the shown workspace on other monitors' bars in this color"
            }

            Text {
              textFormat: Text.PlainText
              visible: root.otherMonitors.length === 0
              x: Style.space(10)
              width: parent.width - Style.space(20)
              text: "Connect another monitor to pick its color"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.otherMonitors

              MonitorColorRow {
                required property var modelData
                monitorName: modelData.name
                description: modelData.description
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(statusLine.implicitHeight, resetButton.implicitHeight)

            Text {
              id: statusLine
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: resetButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.errorText !== "" ? root.errorText : (root.inBar ? "" : "Add Hoverview to the bar to save changes")
              color: root.errorText !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Button {
              id: resetButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Reset to defaults"
              iconText: "\uDB82\uDD9B"
              iconSize: Style.font.body
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.lg
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              hasCursor: root.cursorAt("reset")
              onClicked: root.openConfirm()
              onHovered: function(isHovered) {
                if (isHovered) root.setCursor("reset", 0)
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: resetConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Reset every Hoverview setting to its default?"
        confirmText: "Reset"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmOpen = false
        onConfirmed: root.resetDefaults()
      }
    }
  }

  // Section title with the group's on/off switch riding on its right
  component GroupHeader: Item {
    id: groupHeader

    property string key: ""
    property string title: ""
    property string hint: ""
    property bool rowEnabled: true

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(groupTitle.implicitHeight, groupSwitch.implicitHeight)
    enabled: groupHeader.rowEnabled
    opacity: groupHeader.rowEnabled ? 1 : root.disabledOpacity

    PanelSectionHeader {
      id: groupTitle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: groupHeader.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    MouseArea {
      anchors.fill: groupTitle
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(groupHeader.key, 0)
      onClicked: root.flip(groupHeader.key)
    }

    ToggleSwitch {
      id: groupSwitch
      anchors.right: parent.right
      anchors.rightMargin: Math.max(0, Style.space(8) - groupSwitch.cursorPad)
      anchors.verticalCenter: parent.verticalCenter
      trackHeight: Math.max(14, Style.space(18))
      checked: root.values[groupHeader.key] === true
      hasCursor: root.cursorAt(groupHeader.key)
      foreground: root.foreground
      onHasCursorChanged: if (groupSwitch.hasCursor) root.scrollIntoView(groupHeader)
      onHovered: function(isHovered) {
        if (isHovered) root.setCursor(groupHeader.key, 0)
      }
      onToggled: root.flip(groupHeader.key)

      PanelToolTip {
        visible: groupHeader.hint !== "" && groupSwitch.containsMouse
        text: groupHeader.hint
        fontFamily: root.fontFamily
      }
    }
  }

  // Label on the left, a presentation-only switch on the right; the whole
  // row takes the click, like the shell's Toggle
  component SwitchRow: CursorSurface {
    id: switchRow

    property string key: ""
    property string label: ""
    property string hint: ""
    property bool rowEnabled: true

    width: parent ? parent.width : implicitWidth
    hasCursor: root.cursorAt(switchRow.key)
    onHasCursorChanged: if (switchRow.hasCursor) root.scrollIntoView(switchRow)
    foreground: root.foreground
    enabled: switchRow.rowEnabled
    opacity: switchRow.rowEnabled ? 1 : root.disabledOpacity
    implicitHeight: Math.max(switchLabel.implicitHeight, switchKnob.implicitHeight) + Style.space(10)

    Text {
      id: switchLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: switchKnob.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: switchRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: switchKnob
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      checked: root.values[switchRow.key] === true
      interactive: false
      foreground: root.foreground
    }

    MouseArea {
      id: switchMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(switchRow.key, 0)
      onClicked: root.flip(switchRow.key)
    }

    PanelToolTip {
      visible: switchRow.hint !== "" && switchMouse.containsMouse
      text: switchRow.hint
      fontFamily: root.fontFamily
    }
  }

  // Label, slider and the value; writes when the knob is let go
  component SliderRow: CursorSurface {
    id: sliderRow

    property string key: ""
    property string label: ""
    property string hint: ""
    property string unit: ""
    property bool rowEnabled: true
    readonly property var spec: root.specFor(sliderRow.key)
    readonly property real shown: slider.dragging ? root.snapValue(sliderRow.key, slider.liveValue) : root.values[sliderRow.key]

    width: parent ? parent.width : implicitWidth
    hasCursor: root.cursorAt(sliderRow.key)
    onHasCursorChanged: if (sliderRow.hasCursor) root.scrollIntoView(sliderRow)
    foreground: root.foreground
    enabled: sliderRow.rowEnabled
    opacity: sliderRow.rowEnabled ? 1 : root.disabledOpacity
    implicitHeight: Math.max(sliderLabel.implicitHeight, slider.implicitHeight) + Style.space(4)

    Text {
      id: sliderLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: root.labelWidth
      text: sliderRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    PanelSlider {
      id: slider
      bar: root.bar
      anchors.left: sliderLabel.right
      anchors.right: sliderValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      minimum: sliderRow.spec ? sliderRow.spec.min : 0
      maximum: sliderRow.spec ? sliderRow.spec.max : 1
      step: sliderRow.spec ? sliderRow.spec.step : 1
      integer: true
      value: root.values[sliderRow.key]
      onReleased: function(v) { root.setValue(sliderRow.key, root.snapValue(sliderRow.key, v)) }
    }

    Text {
      id: sliderValue
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(50)
      horizontalAlignment: Text.AlignRight
      text: Math.round(sliderRow.shown) + " " + sliderRow.unit
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    HoverHandler {
      id: sliderHover
      onHoveredChanged: if (hovered) root.setCursor(sliderRow.key, 0)
    }

    PanelToolTip {
      visible: sliderRow.hint !== "" && sliderHover.hovered && !slider.dragging
      text: sliderRow.hint
      fontFamily: root.fontFamily
    }
  }

  // Label with minus / value / plus on the right; h and l step it too
  component StepperRow: CursorSurface {
    id: stepperRow

    property string key: ""
    property string label: ""
    property string hint: ""
    property string valueText: ""
    property bool rowEnabled: true
    readonly property var spec: root.specFor(stepperRow.key)
    readonly property real currentValue: root.values[stepperRow.key]

    width: parent ? parent.width : implicitWidth
    hasCursor: root.cursorAt(stepperRow.key)
    onHasCursorChanged: if (stepperRow.hasCursor) root.scrollIntoView(stepperRow)
    foreground: root.foreground
    enabled: stepperRow.rowEnabled
    opacity: stepperRow.rowEnabled ? 1 : root.disabledOpacity
    implicitHeight: Math.max(stepperLabel.implicitHeight, stepper.implicitHeight) + Style.space(6)

    Text {
      id: stepperLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: stepper.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: stepperRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    HoverHandler {
      id: stepperHover
      onHoveredChanged: if (hovered) root.setCursor(stepperRow.key, 0)
    }

    Row {
      id: stepper
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Button {
        iconText: "\uDB80\uDF74"
        iconSize: Style.font.body
        foreground: root.foreground
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        bordered: true
        enabled: !!stepperRow.spec && stepperRow.currentValue > stepperRow.spec.min
        opacity: enabled ? 1 : root.disabledOpacity
        onClicked: root.stepValue(stepperRow.key, -1)
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(44)
        horizontalAlignment: Text.AlignHCenter
        text: stepperRow.valueText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Button {
        iconText: "\uDB81\uDC15"
        iconSize: Style.font.body
        foreground: root.foreground
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        bordered: true
        enabled: !!stepperRow.spec && stepperRow.currentValue < stepperRow.spec.max
        opacity: enabled ? 1 : root.disabledOpacity
        onClicked: root.stepValue(stepperRow.key, 1)
      }
    }

    PanelToolTip {
      visible: stepperRow.hint !== "" && stepperHover.hovered
      text: stepperRow.hint
      fontFamily: root.fontFamily
    }
  }

  // Label, the current combo (or Off) on the right; Enter or a click records
  component ShortcutRow: CursorSurface {
    id: shortcutRow

    width: parent ? parent.width : implicitWidth
    hasCursor: root.cursorAt("overviewShortcut")
    onHasCursorChanged: if (shortcutRow.hasCursor) root.scrollIntoView(shortcutRow)
    foreground: root.foreground
    implicitHeight: Math.max(shortcutLabel.implicitHeight, shortcutValue.implicitHeight) + Style.space(10)

    Text {
      id: shortcutLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: "Overview shortcut"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: shortcutValue
      textFormat: Text.PlainText
      anchors.left: shortcutLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
      text: root.recording ? "Recording\u2026" : (root.values.overviewShortcut !== "" ? root.values.overviewShortcut : "Off")
      color: root.recording ? Color.accent : (root.values.overviewShortcut !== "" ? root.foreground : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: shortcutMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("overviewShortcut", 0)
      onClicked: {
        root.setCursor("overviewShortcut", 0)
        if (root.recording) root.stopRecording()
        else root.startRecording()
      }
    }

    PanelToolTip {
      visible: shortcutMouse.containsMouse
      text: "Opens the keyboard overview. Click to record a new shortcut."
      fontFamily: root.fontFamily
    }
  }

  // One non-primary monitor: its name and description over its swatches
  component MonitorColorRow: Column {
    id: monitorRow

    property string monitorName: ""
    property string description: ""
    readonly property string section: "monitorColor:" + monitorRow.monitorName
    readonly property var options: root.colorOptionsFor(monitorRow.monitorName)
    readonly property int chosenIndex: root.colorIndexFor(monitorRow.monitorName)

    x: Style.space(4)
    width: parent.width - Style.space(8)
    spacing: Style.space(4)
    enabled: root.values.colorSecondaryMonitor
    opacity: enabled ? 1 : root.disabledOpacity

    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: Style.space(6)
      text: monitorRow.monitorName + (monitorRow.description !== "" ? "  \u00b7  " + monitorRow.description : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: monitorRow.options

        Swatch {
          required property var modelData
          required property int index
          row: monitorRow
          option: modelData
          optionIndex: index
        }
      }
    }
  }

  // A theme color dot, or the labeled "Theme" chip for the default
  component Swatch: BorderSurface {
    id: swatch

    property var row: null
    property var option: ({})
    property int optionIndex: 0
    readonly property bool chosen: swatch.row !== null && swatch.row.chosenIndex === swatch.optionIndex
    readonly property bool hot: swatch.row !== null && root.cursorAt(swatch.row.section, swatch.optionIndex)
    readonly property bool labeled: String(swatch.option.label || "") !== ""

    implicitHeight: Style.space(26)
    implicitWidth: swatch.labeled ? swatchContent.implicitWidth + Style.space(18) : implicitHeight
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: swatch.chosen
      ? Style.selectedFillFor(root.foreground, Color.accent)
      : (swatch.hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
    borderSpec: swatch.hot
      ? Border.controlSpec("hover-cursor", root.foreground, Color.accent)
      : (swatch.chosen ? Border.flat(root.foreground, Math.max(1, Style.space(2))) : Border.none())

    Row {
      id: swatchContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        height: width
        radius: Style.cornerRadius > 0 ? width / 2 : 0
        color: swatch.option.color || "transparent"
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: swatch.labeled
        text: String(swatch.option.label || "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: swatch.chosen
      }
    }

    MouseArea {
      id: swatchMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (swatch.row) root.setCursor(swatch.row.section, swatch.optionIndex)
      onClicked: if (swatch.row) root.chooseMonitorColor(swatch.row.monitorName, swatch.optionIndex)
    }

    PanelToolTip {
      visible: swatchMouse.containsMouse && String(swatch.option.hint || "") !== ""
      text: String(swatch.option.hint || "")
      fontFamily: root.fontFamily
    }
  }
}
