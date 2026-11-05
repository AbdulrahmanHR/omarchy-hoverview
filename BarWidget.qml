import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.abdulrahmanhr.hoverview"

  property int hoveredWorkspaceId: -1
  property Item activeAnchorItem: null
  property bool isHoveringButton: false
  property int originalWorkspaceId: -1
  property bool isPeeking: false

  property int wsRevision: 0

  // Settings card anchor. Buttons are rebuilt when the shown set changes, so
  // the new button for the same workspace id takes it over.
  property int settingsWorkspaceId: -1
  property Item settingsAnchorButton: null

  // Live `hyprctl clients` data keyed by address. Quickshell's
  // toplevel.lastIpcObject is a snapshot that is not updated after the shell
  // starts, so group membership, the shown tab and geometry are read from here.
  property var clientsByAddr: ({})

  // Hyprland events that can change which windows/tabs the preview should show
  readonly property var clientEvents: ["openwindow", "closewindow", "movewindowv2", "activewindowv2", "changefloatingmode", "togglegroup", "moveintogroup", "moveoutofgroup"]

  // User settings from the shell.json layout entry. The shell does not merge
  // manifest defaults, and `omarchy bar set` stores values as strings unless
  // --json is passed, so every value is coerced here with its own default.
  function settingValue(key) {
    var s = root.settings
    return s ? s[key] : undefined
  }

  function settingBool(key, fallback) {
    var v = root.settingValue(key)
    if (typeof v === "boolean") return v
    if (v === 1 || v === 0) return v === 1
    if (typeof v === "string") {
      var s = v.trim().toLowerCase()
      if (s === "true" || s === "on" || s === "yes" || s === "1") return true
      if (s === "false" || s === "off" || s === "no" || s === "0") return false
    }
    return fallback
  }

  function settingNumber(key, fallback, min, max) {
    var v = root.settingValue(key)
    var n = NaN
    if (typeof v === "number") n = v
    else if (typeof v === "string" && v.trim() !== "") n = Number(v.trim())
    if (!isFinite(n)) return fallback
    return Math.min(max, Math.max(min, n))
  }

  function settingInt(key, fallback, min, max) {
    return Math.round(root.settingNumber(key, fallback, min, max))
  }

  function settingString(key, fallback) {
    var v = root.settingValue(key)
    return v === undefined || v === null ? fallback : String(v).trim()
  }

  readonly property int persistentWorkspaces: root.settingInt("persistentWorkspaces", 0, 0, 10)
  readonly property real labelVerticalOffset: root.settingNumber("labelVerticalOffset", 0, -10, 10)
  readonly property bool colorSecondaryMonitor: root.settingBool("colorSecondaryMonitor", true)
  readonly property string secondaryMonitorColor: {
    var c = root.settingString("secondaryMonitorColor", "")
    return /^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/.test(c) ? c : ""
  }
  readonly property bool previewEnabled: root.settingBool("preview", true)
  readonly property int hoverDelayMs: root.settingInt("hoverDelayMs", 220, 0, 2000)
  readonly property int previewWidthSetting: root.settingInt("previewWidth", 420, 240, 800)
  readonly property bool livePreview: root.settingBool("livePreview", true)
  readonly property bool showWindowList: root.settingBool("showWindowList", true)
  readonly property int maxListedWindows: root.settingInt("maxListedWindows", 6, 1, 20)
  readonly property bool highlightLastFocused: root.settingBool("highlightLastFocused", true)
  readonly property bool peekOnHover: root.settingBool("peekOnHover", true)
  readonly property int peekDelayMs: root.settingInt("peekDelayMs", 180, 0, 2000)
  readonly property bool showLayoutShape: root.settingBool("showLayoutShape", true)
  readonly property bool alwaysShowLayoutShapes: root.settingBool("alwaysShowLayoutShapes", false)
  readonly property bool cycleLayoutOnClick: root.settingBool("cycleLayoutOnClick", true)

  onPreviewEnabledChanged: {
    if (!root.previewEnabled) root.close()
  }
  onAlwaysShowLayoutShapesChanged: root.queueModeReads()
  onShowLayoutShapeChanged: root.queueModeReads()

  // ------------------------------------------------- per-monitor workspaces

  // Omarchy 4.5 gives every monitor workspaces 1-10 of its own, which Hyprland
  // numbers in a block of ten per monitor: 1-10, 11-20, and so on (see
  // default/hypr/monitor-workspaces.lua). Each bar shows its own monitor's
  // block, labelled 1-10, and any workspace visiting from another block.
  readonly property int slots: 10
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : ""

  // Connector -> block, from the file Hyprland keeps them in
  property var blocks: ({})

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
    }
    root.blocks = next
  }

  FileView {
    path: root.stateHome + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  function blockOf(id) {
    return Math.floor((id - 1) / root.slots)
  }

  function slotOf(id) {
    return (id - 1) % root.slots + 1
  }

  function slotLabel(id) {
    var slot = root.slotOf(id)
    return slot === root.slots ? "0" : String(slot)
  }

  function activeWorkspaceId() {
    return root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : -1
  }

  // Until Hyprland has written the file, the workspace a monitor shows is in
  // its own block.
  readonly property int block: {
    var b = root.blocks[root.monitorName]
    if (b !== undefined && !isNaN(b)) return b
    var active = root.activeWorkspaceId()
    return active > 0 ? root.blockOf(active) : 0
  }

  // A peek moves the monitor to the hovered workspace for a moment, so the
  // workspace the user is really on is the one the peek started from, and,
  // while the switch back is still in flight, the one it is returning to.
  // Bar state (the pill, the shape, click-to-cycle) follows this, so a click
  // on a peeked workspace commits to it instead of cycling its layout.
  property int revertTargetId: -1

  readonly property int shownWorkspaceId: {
    if (root.isPeeking && root.originalWorkspaceId > 0) return root.originalWorkspaceId
    if (root.revertTargetId > 0) return root.revertTargetId
    return root.activeWorkspaceId()
  }

  Timer {
    id: revertTimer
    interval: 800
    repeat: false
    onTriggered: root.revertTargetId = -1
  }

  // Ends a peek by going back where it started
  function revertPeek() {
    var original = root.originalWorkspaceId
    root.isPeeking = false
    root.originalWorkspaceId = -1
    if (original > 0) {
      root.revertTargetId = original
      revertTimer.restart()
      root.focusWorkspace(original)
    }
  }

  // Ends a peek by staying on the peeked workspace (or moving on from it)
  function dropPeek() {
    peekTimer.stop()
    unpeekTimer.stop()
    root.isPeeking = false
    root.originalWorkspaceId = -1
    root.revertTargetId = -1
    revertTimer.stop()
  }

  Connections {
    target: root.monitor
    function onActiveWorkspaceChanged() {
      if (root.revertTargetId > 0 && root.activeWorkspaceId() === root.revertTargetId) {
        root.revertTargetId = -1
        revertTimer.stop()
      }
      root.queueModeReads()
    }
  }

  onMonitorChanged: root.queueModeReads()
  onBlockChanged: root.queueModeReads()

  // ------------------------------------------------------- layout shapes

  // Each workspace has a layout: a square tiles, a circle scrolls, and a
  // triangle floats. A layout only changes through the layout commands, which
  // ask for a refresh, or a config reload, so each workspace's mode is read
  // once and cached rather than running the script on every switch.
  property var modeCache: ({})
  // modeCache is mutated in place, so bindings depend on this instead
  property int modeRevision: 0
  property int modeGeneration: 0
  property var modeQueue: []
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function modeGlyph(mode) {
    if (mode === "scrolling") return "󰝥"
    if (mode === "floating") return "󰔶"
    return "󱓻"
  }

  function modeName(mode) {
    if (mode === "scrolling") return "Scrolling"
    if (mode === "floating") return "Floating"
    return "Tiling"
  }

  function modeOf(id) {
    var _rev = root.modeRevision
    var mode = root.modeCache[id]
    return mode === undefined ? "" : mode
  }

  function requestMode(id) {
    if (!(id > 0) || root.modeCache[id] !== undefined) return
    if (root.modeQueue.indexOf(id) !== -1) return
    if (modeProc.running && root.modeProcWorkspace === id && root.modeProcGeneration === root.modeGeneration) return
    root.modeQueue.push(id)
  }

  // The workspaces whose shape is on screen: the shown one, every one on the
  // bar when shapes are always shown, and the one the hover card describes.
  function readNeededModes() {
    if (root.alwaysShowLayoutShapes) {
      var ids = root.displayedWorkspaceIds
      for (var i = 0; i < ids.length; i++) root.requestMode(ids[i])
    }
    root.requestMode(root.shownWorkspaceId)
    if (root.hoveredWorkspaceId > 0) root.requestMode(root.hoveredWorkspaceId)
    root.pumpModes()
  }

  // Deferred so a burst of changes reads each workspace once, and never from
  // inside a binding
  function queueModeReads() {
    Qt.callLater(root.readNeededModes)
  }

  function pumpModes() {
    if (modeProc.running) return
    while (root.modeQueue.length > 0) {
      var id = root.modeQueue.shift()
      if (root.modeCache[id] !== undefined) continue
      root.modeProcWorkspace = id
      root.modeProcGeneration = root.modeGeneration
      modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(id)]
      modeProc.running = true
      return
    }
  }

  function refreshModes() {
    root.modeCache = ({})
    root.modeQueue = []
    root.modeGeneration++
    root.modeRevision++
    root.queueModeReads()
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        // A read that started before a refresh may predate the change
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        root.modeCache[root.modeProcWorkspace] = mode
        root.modeRevision++
      }
    }
    // Deferred: the process still reports running while it signals exit
    onRunningChanged: if (!running) Qt.callLater(root.pumpModes)
  }

  // The layout commands act on the focused workspace, so a click on another
  // monitor's bar focuses that monitor first.
  function cycleLayout() {
    if (!root.bar) return
    var command = "omarchy-hyprland-workspace-layout-toggle"
    if (root.monitor && !root.monitor.focused) {
      command = "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + root.monitorName + "\" })") + " >/dev/null && " + command
    }
    root.bar.run(command)
  }

  // Whether Omarchy's own workspaces widget is on the bar too
  readonly property bool builtinWorkspacesOnBar: {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout || typeof layout !== "object") return false
    for (var section in layout) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var id = typeof entry === "string" ? entry : (entry && entry.id)
        if (id === "omarchy.workspaces") return true
      }
    }
    return false
  }

  // Super + L and the default layout ask the workspaces widget to refresh.
  // Only one handler gets a target, and a plugin cannot reach the built-in
  // widget to pass the call on, so the target is left to it while it is on
  // the bar; the notification file below covers that case.
  ShellIpc {
    target: "omarchy.workspaces"
    enabled: !root.builtinWorkspacesOnBar

    function refresh(): void { root.broadcast("refreshModes") }
  }

  // When the built-in widget owns the IPC target, the layout toggle still
  // rewrites its notification state on every change, so watch that too.
  FileView {
    path: root.stateHome + "/omarchy/workspace-layout-notification"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      Qt.callLater(root.refreshModes)
    }
  }

  // ------------------------------------------------------- wheel scrolling

  // A wheel notch moves one entry along the row, and a touchpad adds up its
  // smaller deltas until they make a notch's worth.
  property real wheelAccumulator: 0

  function scrollWorkspaces(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return

    // Holds at either end rather than wrapping, so a touchpad swipe that runs
    // long stops on the last workspace.
    var ids = root.displayedWorkspaceIds
    var index = ids.indexOf(root.shownWorkspaceId)
    if (index === -1) return
    var target = ids[Util.clamp(index - wheel.steps, 0, ids.length - 1)]
    if (target === ids[index]) return
    // Scrolling moves on from a peek rather than back
    if (root.isPeeking) root.dropPeek()
    root.focusWorkspace(target)
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: clientsCollector
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(clientsCollector.text)
          var m = {}
          for (var i = 0; i < data.length; i++) {
            m[root.formatAddress(data[i].address)] = data[i]
          }
          root.clientsByAddr = m
        } catch (e) {}
      }
    }

    // A refresh requested while the previous one ran is replayed afterwards
    onRunningChanged: {
      if (!running && root.clientsRefreshPending) {
        root.clientsRefreshPending = false
        Qt.callLater(root.refreshClients)
      }
    }
  }

  property bool clientsRefreshPending: false

  function refreshClients() {
    if (clientsProc.running) root.clientsRefreshPending = true
    else clientsProc.running = true
  }

  // Workspace ids that hold at least one window, from live `hyprctl clients`
  readonly property var liveOccupiedIds: {
    var ids = {}
    for (var addr in root.clientsByAddr) {
      var c = root.clientsByAddr[addr]
      if (c && c.workspace && c.workspace.id > 0) ids[c.workspace.id] = true
    }
    return ids
  }

  function isOccupied(id) {
    if (root.liveOccupiedIds[id]) return true
    var ws = root.workspaceById(id)
    return !!(ws && ws.toplevels && ws.toplevels.values && ws.toplevels.values.length > 0)
  }

  function ipcFor(toplevel) {
    if (!toplevel) return {}
    return root.clientsByAddr[root.formatAddress(toplevel)] || toplevel.lastIpcObject || {}
  }

  Component.onCompleted: {
    root.refreshClients()
    root.refreshModes()
  }

  // root.bar may already be torn down here, so revert a peek directly
  Component.onDestruction: {
    if (root.isPeeking && root.originalWorkspaceId !== -1) {
      Quickshell.execDetached(["hyprctl", "dispatch", root.focusWorkspaceCommand(root.originalWorkspaceId)])
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      root.wsRevision++
      var name = event ? String(event.name) : ""
      // Always refresh: occupancy is read from the live client list, since
      // workspace.toplevels can miss windows (e.g. after a shell restart)
      if (root.clientEvents.indexOf(name) !== -1) {
        root.refreshClients()
      }
      if (name === "configreloaded") root.refreshModes()
      // Quickshell credits every workspace switch to the focused monitor, as
      // the event doesn't say which one switched, and misses the workspace a
      // monitor falls back to when its own is moved away. Moving workspaces
      // between monitors switches the others, so ask Hyprland for the truth.
      // A workspace that changes number is only learned by asking too. Every
      // bar shares what Hyprland answers, so one asks after a plain switch.
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  // This monitor's block: workspaces 1 to N when kept, the ones with windows,
  // and the one it shows. After them come workspaces only visiting this
  // monitor from another block (an unplugged monitor's, with no room here).
  readonly property var displayedWorkspaceIds: {
    var _rev = root.wsRevision
    var base = root.block * root.slots
    var ids = []
    var guests = []

    function addOwn(id) {
      if (id > base && id <= base + root.slots && ids.indexOf(id) === -1) ids.push(id)
    }

    for (var n = 1; n <= root.persistentWorkspaces; n++) addOwn(base + n)

    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws || ws.id <= 0) continue
      if (root.blockOf(ws.id) === root.block) {
        if (root.isOccupied(ws.id)) addOwn(ws.id)
      } else if (ws.monitor && ws.monitor.name === root.monitorName && guests.indexOf(ws.id) === -1) {
        guests.push(ws.id)
      }
    }

    // Hyprland.workspaces can also miss a workspace, so add live ones directly
    for (var liveId in root.liveOccupiedIds) addOwn(Number(liveId))

    var shown = root.shownWorkspaceId
    if (shown > 0) {
      if (root.blockOf(shown) === root.block) addOwn(shown)
      else if (guests.indexOf(shown) === -1) guests.push(shown)
    }

    ids.sort(function(left, right) { return left - right })
    guests.sort(function(left, right) { return left - right })
    return ids.concat(guests)
  }

  onDisplayedWorkspaceIdsChanged: if (root.alwaysShowLayoutShapes) root.queueModeReads()
  onHoveredWorkspaceIdChanged: root.queueModeReads()

  property FileView themeColorsFile: FileView {
    id: themeColorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  // Theme switches replace the theme directory, which drops the watch above.
  // theme.name is rewritten in place right after the swap, so reload on that.
  property FileView themeNameFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: themeColorsFile.reload()
  }

  function getThemeColor(name, fallback) {
    var txt = themeColorsFile.text()
    if (!txt) return fallback
    var match = txt.match(new RegExp("^\\s*" + name + "\\s*=\\s*[\"']?(#[0-9A-Fa-f]{6})", "m"))
    return match ? match[1] : fallback
  }

  readonly property color secondScreenColor: {
    if (root.secondaryMonitorColor) return root.secondaryMonitorColor
    var _rev = root.wsRevision
    var c = root.getThemeColor("magenta", "")
    if (!c) c = root.getThemeColor("purple", "")
    if (!c) c = root.getThemeColor("orange", "")
    if (!c) c = root.getThemeColor("yellow", "")
    return c ? c : "#b587a0"
  }

  // This bar's monitor has focus, so Super + number acts on it
  readonly property bool monitorFocused: root.monitor !== null && Hyprland.focusedMonitor !== null
    && Hyprland.focusedMonitor.name === root.monitorName

  // A bar on a monitor other than the first marks its shown workspace in the
  // second-screen color instead of the accent, so the screens tell apart
  readonly property bool onSecondScreen: root.colorSecondaryMonitor && root.monitor !== null && root.monitor.id > 0
  readonly property color barAccent: root.onSecondScreen ? root.secondScreenColor : Color.accent

  function isSecondScreenWorkspace(ws) {
    if (!ws) return root.monitor !== null && root.monitor.id > 0
    if (ws.monitor) {
      if (ws.monitor.id !== undefined && ws.monitor.id !== null && ws.monitor.id > 0) return true
    }
    if (ws.lastIpcObject) {
      if (ws.lastIpcObject.monitorID !== undefined && ws.lastIpcObject.monitorID > 0) return true
    }
    return false
  }

  function close() {
    openTimer.stop()
    closeTimer.stop()
    peekTimer.stop()
    unpeekTimer.stop()
    if (root.isPeeking) root.revertPeek()
    previewPopup.open = false
    root.hoveredWorkspaceId = -1
  }

  function formatAddress(target) {
    if (!target) return ""
    var s = ""
    if (typeof target === "string") {
      s = target.trim()
    } else if (typeof target === "object") {
      if (target.lastIpcObject && target.lastIpcObject.address) {
        s = String(target.lastIpcObject.address).trim()
      } else if (target.address) {
        s = String(target.address).trim()
      }
    }
    if (!s) return ""
    if (!s.startsWith("0x") && !s.startsWith("0X")) {
      s = "0x" + s
    }
    return s.toLowerCase()
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceIds() {
    return root.displayedWorkspaceIds
  }

  // A workspace of this monitor's block goes through o.workspaces.focus, which
  // reclaims it from wherever an unplug left it, as Super + number does. A
  // visiting one is focused by its id.
  function focusWorkspaceCommand(id) {
    if (root.blockOf(id) === root.block) {
      var target = root.monitorName !== "" ? ", \"" + root.monitorName + "\"" : ""
      return "o.workspaces.focus(" + root.slotOf(id) + target + ")"
    }
    return "hl.dsp.focus({ workspace = \"" + id + "\" })"
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote(root.focusWorkspaceCommand(id)))
  }

  function focusWindow(target, wsId) {
    if (!root.bar) return
    var addr = root.formatAddress(target)
    if (addr) {
      root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ window = \"address:" + addr + "\" })"))
    } else if (wsId !== undefined && wsId !== -1) {
      focusWorkspace(wsId)
    }
  }

  function commitAndFocusWindow(target, wsId) {
    var addr = root.formatAddress(target)
    var targetWs = (wsId !== undefined && wsId !== -1) ? wsId : root.hoveredWorkspaceId

    root.dropPeek()
    previewPopup.open = false
    root.hoveredWorkspaceId = -1

    if (typeof target === "object" && target && target.wayland && typeof target.wayland.activate === "function") {
      try {
        target.wayland.activate()
      } catch (e) {}
    }

    if (addr) {
      focusWindow(addr, targetWs)
    } else if (targetWs !== undefined && targetWs !== -1) {
      focusWorkspace(targetWs)
    }
  }

  function commitAndFocusWorkspace(wsId) {
    var targetWs = (wsId !== undefined && wsId !== -1) ? wsId : root.hoveredWorkspaceId
    root.dropPeek()
    previewPopup.open = false
    root.hoveredWorkspaceId = -1
    if (targetWs !== undefined && targetWs !== -1) {
      focusWorkspace(targetWs)
    }
  }

  function groupKey(ipc) {
    return ipc.grouped.map(function(x) { return root.formatAddress(x) }).sort().join(",")
  }

  // Lower is better. Hyprland marks only the shown tab of a group `visible`;
  // without that field, the shown tab is the most recently focused one.
  function tabRank(ipc) {
    if (ipc.visible === true) return -1
    return ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 999999
  }

  // A workspace that does not exist yet falls back to this bar's own monitor
  function monitorForWorkspace(ws) {
    if (ws && ws.monitor) return ws.monitor
    return root.monitor
  }

  function iconSource(appClass) {
    var cls = String(appClass || "").trim()
    if (!cls) return ""
    var entry = DesktopEntries.heuristicLookup(cls)
    var icon = String(entry && entry.icon ? entry.icon : "")
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    var names = [icon, cls, cls.toLowerCase()]
    for (var i = 0; i < names.length; i++) {
      if (!names[i]) continue
      var path = Quickshell.iconPath(names[i], true)
      if (path) return path
    }
    return ""
  }

  // Hover detection and debouncing timers
  Timer {
    id: openTimer
    interval: root.hoverDelayMs
    repeat: false
    property Item targetButton: null
    property int targetWsId: -1

    onTriggered: {
      if (root.previewEnabled && !settingsPanel.opened && targetWsId !== -1 && targetButton) {
        root.activeAnchorItem = targetButton
        root.hoveredWorkspaceId = targetWsId
        previewPopup.open = true
      }
    }
  }

  Timer {
    id: closeTimer
    interval: 220
    repeat: false

    onTriggered: {
      if (!previewPopup.containsMouse && !root.isHoveringButton) {
        root.close()
      }
    }
  }

  // Full screen peek timer (when hovering the mini screen)
  Timer {
    id: peekTimer
    interval: root.peekDelayMs
    repeat: false
    onTriggered: {
      if (!root.isPeeking && root.hoveredWorkspaceId !== -1) {
        var currentFocus = root.shownWorkspaceId
        // Focusing another monitor moves focus (and the cursor) off the card
        var sameMonitor = !!(root.monitor && root.monitor.focused && root.activeMonitor
          && root.activeMonitor.name === root.monitorName)
        if (currentFocus > 0 && currentFocus !== root.hoveredWorkspaceId && sameMonitor) {
          root.originalWorkspaceId = currentFocus
          root.isPeeking = true
          root.revertTargetId = -1
          revertTimer.stop()
          root.focusWorkspace(root.hoveredWorkspaceId)
        }
      }
    }
  }

  // Full screen unpeek timer (when leaving the mini screen / popup)
  Timer {
    id: unpeekTimer
    interval: 150
    repeat: false
    onTriggered: {
      // Back on the peeked workspace's own button, the peek holds so a click
      // there commits to it
      if (root.isPeeking && !previewPopup.containsMouse && !root.hoveringPeekedButton()) {
        root.revertPeek()
      }
    }
  }

  property Item hoveredButton: null

  function hoveringPeekedButton() {
    return root.isHoveringButton && root.hoveredButton !== null
      && root.hoveredButton.modelData === root.hoveredWorkspaceId
  }

  function handleButtonHovered(btn, wsId) {
    root.isHoveringButton = true
    root.hoveredButton = btn
    if (!root.previewEnabled || settingsPanel.opened) return
    closeTimer.stop()
    // Moving from the peeked preview back up to that workspace's button keeps
    // the peek, so clicking it commits instead of reading as a click on the
    // shown workspace (which would cycle its layout). Any other button ends it.
    if (root.isPeeking && wsId !== root.hoveredWorkspaceId) root.revertPeek()
    peekTimer.stop()
    unpeekTimer.stop()

    root.refreshClients()

    if (previewPopup.open) {
      root.activeAnchorItem = btn
      root.hoveredWorkspaceId = wsId
    } else {
      openTimer.targetButton = btn
      openTimer.targetWsId = wsId
      openTimer.restart()
    }
  }

  function handleButtonUnhovered(wsId) {
    root.isHoveringButton = false
    // The next button's hover can land before this one's leave
    if (root.hoveredButton && root.hoveredButton.modelData === wsId) root.hoveredButton = null
    openTimer.stop()
    closeTimer.restart()
  }

  // Right-click on a number; the same number closes the card again
  function toggleSettings(btn, wsId) {
    if (settingsPanel.opened && root.settingsWorkspaceId === wsId) {
      settingsPanel.close()
      return
    }
    root.close()
    root.settingsWorkspaceId = wsId
    root.settingsAnchorButton = btn
    settingsPanel.open()
  }

  // Active workspace state and calculations for preview
  readonly property var activeWs: root.workspaceById(root.hoveredWorkspaceId)
  readonly property var activeToplevels: activeWs && activeWs.toplevels ? activeWs.toplevels.values : []
  readonly property var displayedToplevels: activeToplevels.slice(0, root.maxListedWindows)
  readonly property int remainingCount: Math.max(0, activeToplevels.length - root.maxListedWindows)
  readonly property bool isActiveFocused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === root.hoveredWorkspaceId

  readonly property color currentAccentColor: root.colorSecondaryMonitor && root.isSecondScreenWorkspace(root.activeWs) ? root.secondScreenColor : Color.accent

  // Only the shown tab of each group for the visual screen preview
  readonly property var visibleToplevels: {
    var toplevels = root.activeToplevels
    var shownTabs = {}

    for (var i = 0; i < toplevels.length; i++) {
      var ipc = root.ipcFor(toplevels[i])
      if (!ipc.grouped || ipc.grouped.length < 2) continue
      var key = root.groupKey(ipc)
      var rank = root.tabRank(ipc)
      if (!shownTabs[key] || rank < shownTabs[key].rank) {
        shownTabs[key] = { toplevel: toplevels[i], rank: rank }
      }
    }

    var result = []
    for (var j = 0; j < toplevels.length; j++) {
      var tl = toplevels[j]
      if (!tl) continue
      var tlIpc = root.ipcFor(tl)
      if (tlIpc.grouped && tlIpc.grouped.length > 1) {
        if (shownTabs[root.groupKey(tlIpc)].toplevel === tl) result.push(tl)
      } else if (tlIpc.hidden !== true) {
        result.push(tl)
      }
    }
    return result
  }

  // The window on the hovered workspace that was focused most recently
  readonly property var lastFocusedToplevel: {
    var best = null
    var bestRank = 999999
    for (var i = 0; i < root.activeToplevels.length; i++) {
      var ipc = root.ipcFor(root.activeToplevels[i])
      var rank = ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 999999
      if (rank < bestRank) {
        bestRank = rank
        best = root.activeToplevels[i]
      }
    }
    return best
  }

  // True physical vs logical monitor dimensions calculation
  readonly property var activeMonitor: root.monitorForWorkspace(root.activeWs)
  readonly property real monScale: (activeMonitor && activeMonitor.scale > 0) ? activeMonitor.scale : 1.0
  readonly property real monWidth: (activeMonitor && activeMonitor.width > 0) ? (activeMonitor.width / monScale) : 1536
  readonly property real monHeight: (activeMonitor && activeMonitor.height > 0) ? (activeMonitor.height / monScale) : 864
  readonly property real monX: activeMonitor ? activeMonitor.x : 0
  readonly property real monY: activeMonitor ? activeMonitor.y : 0

  readonly property var activeScreen: {
    var name = root.activeMonitor ? root.activeMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === name) return screens[i]
    }
    return null
  }

  // Whole-monitor capture for the focused/peeked workspace; window tiles
  // capture only when it is off, so a hidden view never keeps a capture open
  readonly property bool monitorCaptureActive: root.livePreview && previewPopup.open && (root.isActiveFocused || root.isPeeking) && root.activeScreen !== null
  readonly property bool tileCaptureActive: root.livePreview && !root.monitorCaptureActive

  // Preview canvas size (420px by default)
  readonly property real previewWidth: Style.space(root.previewWidthSetting)
  readonly property real previewHeight: Math.round(previewWidth * (monHeight / (monWidth > 0 ? monWidth : 1536)))
  readonly property real scaleX: previewWidth / (monWidth > 0 ? monWidth : 1536)
  readonly property real scaleY: previewHeight / (monHeight > 0 ? monHeight : 864)

  readonly property string hoveredMode: root.hoveredWorkspaceId > 0 ? root.modeOf(root.hoveredWorkspaceId) : ""

  // Omarchy 4.5's bar draws the open-panel mark under this item, so it sits
  // under the workspace whose card or settings are open, not mid-widget.
  readonly property Item openPanelIndicatorItem: settingsPanel.opened && root.settingsAnchorButton
    ? root.settingsAnchorButton
    : (previewPopup.open && root.activeAnchorItem ? root.activeAnchorItem : null)

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.displayedWorkspaceIds.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.displayedWorkspaceIds

      WidgetButton {
        id: btn
        required property int modelData
        required property int index

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: root.isOccupied(modelData)
        // The workspace this monitor really shows, not one a peek is showing
        readonly property bool shown: root.shownWorkspaceId === modelData
        // Solid on the focused screen's bar, faded on the others, so the bar
        // tells which screen Super + number will act on
        readonly property bool lit: shown && root.monitorFocused
        readonly property string mode: root.modeOf(modelData)
        readonly property bool showShape: mode !== "" && (root.alwaysShowLayoutShapes || (root.showLayoutShape && shown))
        readonly property bool floatingShape: showShape && mode === "floating"
        readonly property color markColor: shown
          ? (lit ? root.barAccent : Util.alpha(root.barAccent, 0.4))
          : Util.alpha(btn.foreground, 0.16)
        // The first workspace visiting from another block, set apart by a gap
        readonly property bool firstGuest: index > 0 && root.blockOf(modelData) !== root.block
          && root.blockOf(root.displayedWorkspaceIds[index - 1]) === root.block

        Layout.leftMargin: firstGuest && !root.vertical ? Style.space(6) : 0
        Layout.topMargin: firstGuest && root.vertical ? Style.space(6) : 0

        bar: root.bar
        // Every workspace keeps its number; a shape, when shown, sits behind it
        text: root.slotLabel(modelData)
        active: lit
        activeColor: Color.background
        foreground: bar ? bar.barForeground : Color.foreground
        opacity: occupied || shown ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        // A triangle needs a wider slot so it doesn't run into its neighbours
        fixedWidth: root.vertical ? root.barSize : Style.space(floatingShape ? 26 : 20)
        fixedHeight: root.barSize

        // WidgetButton centers the figures of a number label itself, so the
        // user's nudge is added on top, and only once there is one to add.
        property Item numberLabel: null
        property bool offsetBound: false

        FontMetrics {
          id: figureMetrics
          font.family: btn.fontFamily
          font.pixelSize: btn.fontSize
          font.bold: btn.shown
        }

        function bindLabelOffset() {
          if (btn.offsetBound || !btn.numberLabel || root.labelVerticalOffset === 0) return
          btn.offsetBound = true
          btn.numberLabel.anchors.verticalCenterOffset = Qt.binding(function() {
            var centered = !btn.centerFigures || btn.vertical || btn.text.indexOf("\n") !== -1 ? 0
              : (figureMetrics.descent - figureMetrics.ascent + figureMetrics.tightBoundingRect("0").height) / 2
            // Style.space() returns 0 for negative input, so scale the magnitude
            var v = root.labelVerticalOffset
            return centered + (v < 0 ? -Style.space(-v) : Style.space(v))
          })
        }

        Connections {
          target: root
          function onLabelVerticalOffsetChanged() { btn.bindLabelOffset() }
        }

        Component.onCompleted: {
          for (var i = 0; i < children.length; i++) {
            var child = children[i]
            if (child && child.font && "verticalAlignment" in child && "renderType" in child) {
              child.font.bold = Qt.binding(function() { return btn.shown })
              btn.numberLabel = child
              break
            }
          }
          btn.bindLabelOffset()
          if (btn.modelData === root.settingsWorkspaceId) root.settingsAnchorButton = btn
        }

        // Accent pill behind the shown workspace's number, or its layout
        // shape (square tiles, circle scrolls, triangle floats) when shown
        Rectangle {
          z: -1
          anchors.centerIn: parent
          width: Style.space(20)
          height: Style.space(20)
          radius: Style.space(4)
          color: btn.markColor
          visible: btn.shown && !btn.showShape
        }

        OpticalGlyph {
          z: -1
          visible: btn.showShape
          // Workspaces not on screen get a smaller mark around the same number
          // A triangle is drawn larger, since its middle, where the number
          // sits, is narrower than a square's
          readonly property real markSize: btn.floatingShape ? (btn.shown ? 26 : 24) : (btn.shown ? 20 : 17)
          width: Style.space(markSize + 2)
          height: width
          anchors.centerIn: parent
          // A triangle's centroid sits a sixth of its height below the middle
          // of its bounds. Raising it halfway there lets the number sit in
          // the wide part without the tip touching the edge of the bar.
          anchors.verticalCenterOffset: btn.floatingShape ? -paintedHeight / 12 : 0
          text: root.modeGlyph(btn.mode)
          fontFamily: btn.fontFamily
          fontSize: Style.font.body
          paintedSize: Style.space(markSize)
          color: btn.markColor
          scale: btn.pressScale
        }

        onPressed: function(button) {
          if (button === Qt.RightButton) {
            root.toggleSettings(btn, btn.modelData)
            return
          }
          // Only a click on the workspace that is really on screen cycles its
          // layout. During a peek, or while one is switching back, the click
          // commits to the workspace instead.
          var onScreen = btn.shown && root.activeWorkspaceId() === btn.modelData
            && !root.isPeeking && root.revertTargetId <= 0
          if (button === Qt.LeftButton && onScreen && root.cycleLayoutOnClick) root.cycleLayout()
          else root.commitAndFocusWorkspace(btn.modelData)
        }
        onWheelMoved: function(delta) { root.scrollWorkspaces(delta) }

        HoverHandler {
          id: hov
          onHoveredChanged: {
            if (hovered) {
              root.handleButtonHovered(btn, btn.modelData)
            } else {
              root.handleButtonUnhovered(btn.modelData)
            }
          }
        }
      }
    }
  }

  Connections {
    target: previewPopup
    function onContainsMouseChanged() {
      if (!previewPopup.containsMouse && !root.isHoveringButton) {
        closeTimer.restart()
        if (root.isPeeking) {
          unpeekTimer.restart()
        }
      } else if (previewPopup.containsMouse) {
        closeTimer.stop()
        unpeekTimer.stop()
      }
    }
    function onOpenChanged() {
      if (!previewPopup.open) {
        peekTimer.stop()
        unpeekTimer.stop()
        if (root.isPeeking) root.revertPeek()
      }
    }
  }

  SettingsPanel {
    id: settingsPanel
    bar: root.bar
    anchorItem: root.settingsAnchorButton || root
  }

  // Hover preview popup card
  PopupCard {
    id: previewPopup
    anchorItem: root.activeAnchorItem || root
    bar: root.bar
    owner: root
    triggerMode: "hover"
    open: false
    padding: Style.space(12)
    contentWidth: previewPopup.fittedContentWidth(root.previewWidth + previewPopup.padding * 2 + Border.left(previewPopup.borderSpec) + Border.right(previewPopup.borderSpec))
    contentHeight: previewPopup.fittedContentHeight(popupColumn.implicitHeight)

    Column {
      id: popupColumn
      width: root.previewWidth
      spacing: Style.space(10)

      // 1. Header (Workspace title & window count tag)
      RowLayout {
        width: parent.width

        Text {
          text: "Workspace " + (root.hoveredWorkspaceId > 0 ? root.slotLabel(root.hoveredWorkspaceId) : "")
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          color: Color.popups.text
        }

        Text {
          textFormat: Text.PlainText
          visible: root.activeMonitor !== null
          text: "• " + (root.activeMonitor ? root.activeMonitor.name : "")
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
        }

        Text {
          textFormat: Text.PlainText
          visible: root.hoveredMode !== ""
          text: "• " + root.modeGlyph(root.hoveredMode) + " " + root.modeName(root.hoveredMode)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
        }

        Item { Layout.fillWidth: true }

        Rectangle {
          radius: Style.space(4)
          color: (root.isActiveFocused || root.isPeeking) ? root.currentAccentColor : Style.normalFillFor(Color.popups.text, root.currentAccentColor)
          implicitWidth: statusText.implicitWidth + Style.space(12)
          implicitHeight: statusText.implicitHeight + Style.space(6)

          Text {
            id: statusText
            anchors.centerIn: parent
            text: root.isPeeking ? "Peeking Full Screen" : (root.isActiveFocused ? "Active Screen" : (root.activeToplevels.length > 0 ? (root.activeToplevels.length + (root.activeToplevels.length === 1 ? " window" : " windows")) : "Empty"))
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: (root.isActiveFocused || root.isPeeking) ? Color.background : Color.popups.text
          }
        }
      }

      // 2. Screen Visual Preview Canvas (hovering peeks full screen)
      Rectangle {
        id: previewScreen
        width: root.previewWidth
        height: root.previewHeight
        radius: Style.cornerRadius
        color: "#111218"
        border.color: root.isPeeking ? root.currentAccentColor : Color.popups.border
        border.width: root.isPeeking ? 2 : 1
        clip: true

        // Full screen peek on hover
        HoverHandler {
          id: screenHover
          onHoveredChanged: {
            if (hovered) {
              unpeekTimer.stop()
              if (root.peekOnHover) peekTimer.restart()
            } else {
              peekTimer.stop()
              if (!previewPopup.containsMouse) {
                unpeekTimer.restart()
              }
            }
          }
        }

        // Click on preview background to jump directly to workspace
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            var targetWs = root.hoveredWorkspaceId
            root.commitAndFocusWorkspace(targetWs)
          }
        }

        // Live monitor screencopy view if currently focused or peeking
        ScreencopyView {
          id: liveMonitorCopy
          anchors.fill: parent
          captureSource: root.monitorCaptureActive ? root.activeScreen : null
          live: root.monitorCaptureActive
          paintCursor: false
          visible: root.monitorCaptureActive && hasContent
        }

        // Proportional window layout representation (visible/active tabs only)
        Repeater {
          model: root.visibleToplevels

          Item {
            id: winItem
            required property var modelData
            readonly property bool isLastFocused: root.highlightLastFocused ? modelData === root.lastFocusedToplevel : modelData.activated === true
            visible: !liveMonitorCopy.visible

            readonly property var ipc: root.ipcFor(modelData)
            readonly property string iconSrc: root.iconSource(ipc.class)
            readonly property real rawX: (ipc.at && ipc.at.length > 0) ? Number(ipc.at[0]) : 0
            readonly property real rawY: (ipc.at && ipc.at.length > 1) ? Number(ipc.at[1]) : 0
            readonly property real rawW: (ipc.size && ipc.size.length > 0) ? Number(ipc.size[0]) : root.monWidth
            readonly property real rawH: (ipc.size && ipc.size.length > 1) ? Number(ipc.size[1]) : root.monHeight

            readonly property real localX: rawX - root.monX
            readonly property real localY: rawY - root.monY

            x: Math.max(0, Math.min(previewScreen.width - width, localX * root.scaleX))
            y: Math.max(0, Math.min(previewScreen.height - height, localY * root.scaleY))
            width: Math.max(Style.space(36), Math.min(previewScreen.width - x, rawW * root.scaleX))
            height: Math.max(Style.space(28), Math.min(previewScreen.height - y, rawH * root.scaleY))

            Rectangle {
              id: tile
              anchors.fill: parent
              radius: Style.space(4)
              color: Qt.rgba(0.14, 0.16, 0.22, 0.95)
              border.color: winItem.isLastFocused ? root.currentAccentColor : Qt.rgba(0.35, 0.40, 0.52, 0.85)
              border.width: winItem.isLastFocused ? 2 : 1
              clip: true

              // Screencopy of individual window if available
              ScreencopyView {
                id: winCopy
                anchors.fill: parent
                captureSource: root.tileCaptureActive && modelData.wayland ? modelData.wayland : null
                live: root.tileCaptureActive
                paintCursor: false
                visible: root.tileCaptureActive && hasContent
              }

              // Mini window title header bar
              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: Style.space(16)
                color: winItem.isLastFocused
                  ? Qt.rgba(root.currentAccentColor.r * 0.35, root.currentAccentColor.g * 0.35, root.currentAccentColor.b * 0.35, 0.96)
                  : Qt.rgba(0.18, 0.21, 0.30, 0.96)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 4
                  anchors.rightMargin: 4
                  spacing: 4

                  Item {
                    width: Style.space(11)
                    height: Style.space(11)
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                      id: miniImg
                      anchors.fill: parent
                      source: winItem.iconSrc
                      fillMode: Image.PreserveAspectFit
                      // Decode at physical pixels so icons stay sharp on scaled displays
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      asynchronous: true
                      visible: status === Image.Ready
                    }

                    Text {
                      anchors.centerIn: parent
                      visible: !miniImg.visible
                      text: "\uDB82\uDCC6"
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.space(8)
                      color: Color.popups.text
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(16)
                    text: modelData.title || ipc.class || ""
                    color: Color.popups.text
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption * 0.85
                    font.bold: winItem.isLastFocused
                    elide: Text.ElideRight
                  }
                }
              }

              // App center watermark badge
              Column {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: Style.space(8)
                spacing: Style.space(4)
                visible: !winCopy.visible && tile.width > Style.space(60) && tile.height > Style.space(44)

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.min(tile.height * 0.35, Style.space(26))
                  height: width
                  source: winItem.iconSrc
                  fillMode: Image.PreserveAspectFit
                  // Decode at physical pixels so icons stay sharp on scaled displays
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: ipc.class ? (ipc.class.charAt(0).toUpperCase() + ipc.class.slice(1)) : ""
                  color: Color.popups.text
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  visible: tile.width > Style.space(80)
                }
              }
            }

            // Clicking directly on a mini window tile focuses that exact window
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.commitAndFocusWindow(winItem.modelData, root.hoveredWorkspaceId)
              }
            }
          }
        }

        // Empty state
        Column {
          anchors.centerIn: parent
          spacing: Style.space(6)
          visible: root.activeToplevels.length === 0

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "\uDB80\uDDC4"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title * 1.3
            color: Color.muted
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No windows open on this workspace"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
      }

      // 3. Small List Under It (Windows / Tabs in this workspace)
      Rectangle {
        visible: root.showWindowList
        width: parent.width
        height: 1
        color: Color.popups.border
        opacity: 0.5
      }

      Column {
        visible: root.showWindowList
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.displayedToplevels

          Rectangle {
            id: listItem
            required property var modelData
            width: parent.width
            height: Style.space(34)
            radius: Style.space(5)

            readonly property var itemIpc: root.ipcFor(modelData)
            readonly property string appClass: (itemIpc.class || "").toLowerCase()
            readonly property string winTitle: modelData.title || itemIpc.title || appClass
            readonly property bool isLastFocused: root.highlightLastFocused ? modelData === root.lastFocusedToplevel : modelData.activated === true

            color: rowMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(3)
              height: parent.height * 0.6
              radius: width / 2
              color: root.currentAccentColor
              visible: listItem.isLastFocused
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)

              Item {
                width: Style.space(20)
                height: Style.space(20)
                anchors.verticalCenter: parent.verticalCenter

                Image {
                  id: listImg
                  anchors.fill: parent
                  source: root.iconSource(listItem.itemIpc.class)
                  fillMode: Image.PreserveAspectFit
                  // Decode at physical pixels so icons stay sharp on scaled displays
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: !listImg.visible
                  text: "\uDB82\uDCC6"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.space(13)
                  color: Color.muted
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(38)
                spacing: 1

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: winTitle
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body * 0.95
                  font.bold: listItem.isLastFocused
                  color: listItem.isLastFocused ? root.currentAccentColor : Color.popups.text
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: appClass ? (appClass.charAt(0).toUpperCase() + appClass.slice(1)) : "Application"
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption * 0.85
                  color: Color.muted
                  elide: Text.ElideRight
                  visible: text.toLowerCase() !== winTitle.toLowerCase()
                }
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.commitAndFocusWindow(listItem.modelData, root.hoveredWorkspaceId)
              }
            }
          }
        }

        Text {
          visible: root.remainingCount > 0
          width: parent.width
          text: "+ " + root.remainingCount + " more windows"
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(2)
        }

        Text {
          visible: root.activeToplevels.length === 0
          width: parent.width
          text: "Click to switch to this workspace"
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
        }
      }
    }
  }
}
