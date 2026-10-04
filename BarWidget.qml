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

  onPreviewEnabledChanged: {
    if (!root.previewEnabled) root.close()
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

  function ipcFor(toplevel) {
    if (!toplevel) return {}
    return root.clientsByAddr[root.formatAddress(toplevel)] || toplevel.lastIpcObject || {}
  }

  Component.onCompleted: {
    root.refreshClients()
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
      if (previewPopup.open && event && root.clientEvents.indexOf(event.name) !== -1) {
        root.refreshClients()
      }
    }
  }

  readonly property var displayedWorkspaceIds: {
    var _rev = root.wsRevision
    var ids = []
    var values = Hyprland.workspaces.values
    var focusedWs = Hyprland.focusedWorkspace
    var focusedId = focusedWs ? focusedWs.id : 1

    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws) continue
      var id = ws.id
      if (id > 0 && id <= 10) {
        var hasWindows = ws.toplevels && ws.toplevels.values && ws.toplevels.values.length > 0
        var isFocused = (id === focusedId)
        if (hasWindows || isFocused) {
          if (ids.indexOf(id) === -1) ids.push(id)
        }
      }
    }

    if (focusedId > 0 && focusedId <= 10 && ids.indexOf(focusedId) === -1) {
      ids.push(focusedId)
    }

    for (var n = 1; n <= root.persistentWorkspaces; n++) {
      if (ids.indexOf(n) === -1) ids.push(n)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

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

  function isSecondScreenWorkspace(ws) {
    if (!ws) return false
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
    if (root.isPeeking) {
      if (root.originalWorkspaceId !== -1) {
        root.focusWorkspace(root.originalWorkspaceId)
      }
      root.isPeeking = false
      root.originalWorkspaceId = -1
    }
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

  function focusWorkspaceCommand(id) {
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

    peekTimer.stop()
    unpeekTimer.stop()
    root.isPeeking = false
    root.originalWorkspaceId = -1
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
    peekTimer.stop()
    unpeekTimer.stop()
    root.isPeeking = false
    root.originalWorkspaceId = -1
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
    var win = root.QsWindow.window
    if (win && win.screen) return Hyprland.monitorFor(win.screen)
    return Hyprland.focusedMonitor
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
        var currentFocus = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
        // Focusing another monitor moves focus (and the cursor) off the card
        var focusedMon = Hyprland.focusedMonitor
        var sameMonitor = !!(root.activeMonitor && focusedMon && root.activeMonitor.name === focusedMon.name)
        if (currentFocus !== root.hoveredWorkspaceId && sameMonitor) {
          root.originalWorkspaceId = currentFocus
          root.isPeeking = true
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
      if (root.isPeeking && !previewPopup.containsMouse) {
        if (root.originalWorkspaceId !== -1) {
          root.focusWorkspace(root.originalWorkspaceId)
        }
        root.isPeeking = false
        root.originalWorkspaceId = -1
      }
    }
  }

  function handleButtonHovered(btn, wsId) {
    root.isHoveringButton = true
    if (!root.previewEnabled || settingsPanel.opened) return
    closeTimer.stop()
    if (root.isPeeking) {
      if (root.originalWorkspaceId !== -1) {
        root.focusWorkspace(root.originalWorkspaceId)
      }
      root.isPeeking = false
      root.originalWorkspaceId = -1
    }
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

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property bool isSecondScreen: root.colorSecondaryMonitor && root.isSecondScreenWorkspace(workspace)

        bar: root.bar
        text: modelData === 10 ? "0" : String(modelData)
        active: focused
        activeColor: Color.background
        foreground: isSecondScreen ? root.secondScreenColor : (bar ? bar.barForeground : Color.foreground)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize

        Component.onCompleted: {
          for (var i = 0; i < children.length; i++) {
            if (children[i] && children[i].font) {
              children[i].font.bold = Qt.binding(function() { return btn.focused })
              // Style.space() returns 0 for negative input, so scale the magnitude
              children[i].anchors.verticalCenterOffset = Qt.binding(function() {
                var v = root.labelVerticalOffset
                return v < 0 ? -Style.space(-v) : Style.space(v)
              })
            }
          }
          if (btn.modelData === root.settingsWorkspaceId) root.settingsAnchorButton = btn
        }

        Rectangle {
          z: -1
          anchors.centerIn: parent
          width: Style.space(20)
          height: Style.space(20)
          radius: Style.space(4)
          color: btn.isSecondScreen ? root.secondScreenColor : Color.accent
          visible: btn.focused
        }

        onPressed: function(button) {
          if (button === Qt.RightButton) root.toggleSettings(btn, btn.modelData)
          else root.commitAndFocusWorkspace(modelData)
        }

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
        if (root.isPeeking) {
          if (root.originalWorkspaceId !== -1) {
            root.focusWorkspace(root.originalWorkspaceId)
          }
          root.isPeeking = false
          root.originalWorkspaceId = -1
        }
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
          text: "Workspace " + (root.hoveredWorkspaceId === 10 ? "0" : String(root.hoveredWorkspaceId))
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
