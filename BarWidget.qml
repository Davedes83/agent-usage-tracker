import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar face of the Agent Usage Tracker.
//
// The widget owns the data pipeline (scripts/usage.py) and the popup identity
// contract the bar expects: open / close / opened on the widget root, with the
// nested Panel.qml forwarded through. The panel itself is a passive renderer
// that receives a fresh `stats` object each poll, so the numbers in the bar and
// in the popup can never disagree.
BarWidget {
  id: root
  moduleName: "davedes.agent-usage-tracker"

  // ---- collector state
  property var stats: ({})
  property bool ready: false
  property bool busy: false
  property string problem: ""
  property double lastUpdated: 0

  readonly property var windows: (stats && stats.windows) ? stats.windows : ({})
  readonly property var today: windows.today || ({})
  readonly property var allTime: windows.all || ({})
  readonly property var openrouter: (stats && stats.openrouter) ? stats.openrouter : ({})

  // ---- settings
  function intSetting(name, fallback, min, max) {
    var v = Number(setting(name, fallback))
    if (!isFinite(v)) v = Number(fallback)
    if (!isFinite(v)) v = min
    return Math.max(min, Math.min(max, Math.round(v)))
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int textSize: intSetting("fontSize", Style.font.caption, 8, 28)

  // ---- formatting
  function n(value) {
    var x = Number(value)
    return isFinite(x) ? x : 0
  }

  // "Processed" tokens: what the model actually read and wrote. Cache traffic
  // is reported separately in the tooltip and panel because it dwarfs the rest
  // and would make the bar figure meaningless.
  readonly property real todayTokens: n(today.input) + n(today.output) + n(today.reasoning)
  readonly property real todayCache: n(today.cache_read) + n(today.cache_write)
  readonly property real todaySpend: n(today.cost)
  readonly property int todaySessions: n(today.sessions)

  readonly property string labelText: "󰚩"

  readonly property string tipText: {
    if (!ready) return busy ? "Agent Usage \u2014 collecting\u2026" : "Agent Usage \u2014 no data yet"
    var lines = []
    lines.push("Today  " + Model.fmtTokens(todayTokens) + " tokens  \u00b7  " + Model.fmtCost(todaySpend))
    if (todayCache > 0) lines.push("Cache today  " + Model.fmtTokens(todayCache) + " read/write")
    lines.push(todaySessions + (todaySessions === 1 ? " session today" : " sessions today"))
    lines.push("Lifetime  " + Model.fmtCost(allTime.cost) + "  \u00b7  " + n(allTime.sessions) + " sessions")
    if (openrouter.ok === true)
      lines.push("OpenRouter  " + Model.fmtCost(openrouter.credits_used) + " of " + Model.fmtCost(openrouter.credits_total) + " credits")
    else if (openrouter.error) lines.push("OpenRouter  " + openrouter.error)
    lines.push("Left: details  \u00b7  Middle: refresh")
    return lines.join("\n")
  }

  // ---- collection
  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  function applyStats(raw) {
    var text = String(raw || "").trim()
    busy = false
    if (text === "") {
      // Empty stdout is a failure, not "no data yet": say so instead of
      // leaving the last good numbers (or a blank panel) with no explanation.
      problem = "Collector returned no data"
      return
    }
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (err) {
      problem = "Could not parse usage data"
      return
    }
    if (!parsed || !parsed.windows) {
      problem = "Collector returned no usage data"
      return
    }
    stats = parsed
    ready = true
    problem = ""
    lastUpdated = Date.now()
    injectPanel()
  }

  function refresh() {
    if (collectProc.running) return
    busy = true
    collectProc.running = true
  }

  // ---- popup identity (Bar.findPanelWidget / shell.summon / popout switching)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // Track whether we've already wired the panel to avoid double-inject
  property bool _panelInjected: false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if (!root._panelInjected) {
      root._panelInjected = true
      if ("bar" in target) target.bar = root.bar
      if ("settings" in target) target.settings = root.settings
      if ("anchorItem" in target) target.anchorItem = button
      if ("hostWidget" in target) target.hostWidget = root
    }
    if ("stats" in target) {
      target.stats = root.stats
    }
  }

  onBarChanged: { root._panelInjected = false; injectPanel() }
  onSettingsChanged: injectPanel()
  onStatsChanged: injectPanel()
  // Only refresh when the panel *closes* after being opened with stale data
  onOpenedChanged: { if (!opened && ready) refresh() }

  Component.onCompleted: refresh()

  Process {
    id: collectProc
    command: ["python3", root.pathFromUrl(Qt.resolvedUrl("scripts/usage.py"))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStats(text)
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: console.warn("agent-usage stderr:", text) }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.problem = "Collector exited with code " + exitCode
        // Schedule a retry instead of leaving it stuck
        root.retryTimer.restart()
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 5000
    repeat: false
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "davedes.agent-usage-tracker"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  Loader {
    id: panelLoader
    active: true
    asynchronous: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    fontSize: root.textSize
    tooltipText: root.tipText
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else root.refresh()
    }
  }

  Component.onDestruction: {
    if (collectProc.running) collectProc.kill()
  }
}