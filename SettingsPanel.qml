import QtQuick
import QtQuick.Controls as QQC
import Quickshell
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
  property bool readQueued: false
  // Bumped per write; a read that began before a write is stale
  property int writeGen: 0
  property string errorText: ""
  property string themeText: ""

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
    var list = ["persistentWorkspaces", "labelVerticalOffset", "preview"]
    if (v.preview) {
      list.push("hoverDelayMs", "previewWidth", "livePreview", "showWindowList")
      if (v.showWindowList) list.push("maxListedWindows")
      list.push("highlightLastFocused", "peekOnHover")
      if (v.peekOnHover) list.push("peekDelayMs")
    }
    list.push("colorSecondaryMonitor")
    if (v.colorSecondaryMonitor) list.push("secondaryMonitorColor")
    list.push("reset")
    return list
  }

  // Keys, defaults and ranges; keep in sync with BarWidget.qml and manifest.json
  function specList() {
    return [
      { key: "persistentWorkspaces", type: "int", fallback: 0, min: 0, max: 10, step: 1 },
      { key: "labelVerticalOffset", type: "number", fallback: 0, min: -10, max: 10, step: 0.5 },
      { key: "colorSecondaryMonitor", type: "bool", fallback: true },
      { key: "secondaryMonitorColor", type: "color", fallback: "" },
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
    var regions = ["left", "center", "right"]
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
    path: root.opened ? root.shellConfigPath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
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

  function chooseColor(index) {
    var option = root.colorOptions[index]
    if (!option) return
    root.selectedIndex = index
    if (option.value !== root.values.secondaryMonitorColor) root.setValue("secondaryMonitorColor", option.value, true)
  }

  function resetDefaults() {
    root.confirmOpen = false
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

  // What "" resolves to in BarWidget.qml
  readonly property string themeTint: root.themeColor("magenta") || root.themeColor("purple")
    || root.themeColor("orange") || root.themeColor("yellow") || "#b587a0"

  readonly property var colorOptions: {
    var list = [{ value: "", color: root.themeTint, label: "Theme", hint: "Follow the theme's magenta" }]
    var seen = {}
    var names = ["red", "orange", "yellow", "green", "cyan", "blue", "magenta", "accent"]
    for (var i = 0; i < names.length; i++) {
      var c = root.themeColor(names[i])
      if (!c || seen[c.toLowerCase()]) continue
      seen[c.toLowerCase()] = true
      list.push({ value: c, color: c, label: "", hint: names[i].charAt(0).toUpperCase() + names[i].slice(1) + "  " + c })
    }
    var current = root.values.secondaryMonitorColor
    if (current !== "" && !seen[current.toLowerCase()]) list.push({ value: current, color: current, label: "", hint: "Custom  " + current })
    return list
  }

  readonly property int colorIndex: {
    var current = String(root.values.secondaryMonitorColor).toLowerCase()
    for (var i = 0; i < root.colorOptions.length; i++) {
      if (root.colorOptions[i].value.toLowerCase() === current) return i
    }
    return 0
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
    return section === "secondaryMonitorColor" ? root.colorIndex : 0
  }

  // A row that gets disabled hands the cursor to the toggle above it
  function clampCursor() {
    var list = root.sections
    if (list.indexOf(root.focusSection) !== -1) return
    var order = ["persistentWorkspaces", "labelVerticalOffset", "preview", "hoverDelayMs", "previewWidth",
      "livePreview", "showWindowList", "maxListedWindows", "highlightLastFocused", "peekOnHover",
      "peekDelayMs", "colorSecondaryMonitor", "secondaryMonitorColor", "reset"]
    for (var i = order.indexOf(root.focusSection); i >= 0; i--) {
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
    var spec = root.specFor(root.focusSection)
    if (!spec) return
    if (spec.type === "int" || spec.type === "number") root.stepValue(spec.key, dx)
    else if (spec.type === "color") root.selectedIndex = Math.max(0, Math.min(root.colorOptions.length - 1, root.selectedIndex + dx))
  }

  function activateCursor() {
    root.clampCursor()
    var key = root.focusSection
    if (key === "reset") root.openConfirm()
    else if (key === "secondaryMonitorColor") root.chooseColor(root.selectedIndex)
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
              hint: "Keep workspaces 1 to N on the bar, even when empty"
              valueText: root.workspacesText(root.values.persistentWorkspaces)
            }

            StepperRow {
              key: "labelVerticalOffset"
              label: "Label offset"
              hint: "Nudge the numbers up or down for fonts that sit off-center"
              valueText: root.offsetText(root.values.labelVerticalOffset)
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

          // ---------- Second monitor ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            GroupHeader {
              key: "colorSecondaryMonitor"
              title: "SECOND MONITOR"
              hint: "Tint workspaces that live on another monitor"
            }

            Flow {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              spacing: Style.space(6)
              enabled: root.values.colorSecondaryMonitor
              opacity: enabled ? 1 : root.disabledOpacity

              Repeater {
                model: root.colorOptions

                Swatch {
                  required property var modelData
                  required property int index
                  option: modelData
                  optionIndex: index
                }
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

  // A theme color dot, or the labeled "Theme" chip for the empty value
  component Swatch: BorderSurface {
    id: swatch

    property var option: ({})
    property int optionIndex: 0
    readonly property bool chosen: root.colorIndex === swatch.optionIndex
    readonly property bool hot: root.cursorAt("secondaryMonitorColor", swatch.optionIndex)
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
      onEntered: root.setCursor("secondaryMonitorColor", swatch.optionIndex)
      onClicked: root.chooseColor(swatch.optionIndex)
    }

    PanelToolTip {
      visible: swatchMouse.containsMouse && String(swatch.option.hint || "") !== ""
      text: String(swatch.option.hint || "")
      fontFamily: root.fontFamily
    }
  }
}
