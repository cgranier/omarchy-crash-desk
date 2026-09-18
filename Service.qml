import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads systemd-coredump's history and remembers how far you have looked.
Item {
  id: root

  property var settings: ({})

  property var crashes: []
  property var groups: []
  property int fresh: 0
  property double seenMs: 0
  property double now: Date.now()
  property string summary: "Checking…"
  property bool agentAvailable: false
  property bool loaded: false
  property string actionStatus: ""

  readonly property int days: intSetting("days", 14, 1, 90)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 15, 3600)
  readonly property bool allUsers: setting("allUsers", false) === true
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-crashdesk"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (listProcess.running) return
    // The uid rides along on the first line so crashes can be filtered to this
    // user. coredumpctl exits 1 with "No coredumps found" when the window is
    // empty, which is an answer, not a failure.
    listProcess.command = ["sh", "-c", 'id -u; coredumpctl list --json=short --no-pager --since="-$1days" 2>/dev/null; exit 0', "sh", String(days)]
    listProcess.running = true
    if (!agentProcess.running) agentProcess.running = true
  }

  function apply(raw) {
    var parsed = Model.parseListing(raw)
    crashes = Model.crashesFrom(parsed.entries, parsed.uid, allUsers)
    recount()
    loaded = true
  }

  function recount() {
    now = Date.now()
    groups = Model.groupByProgram(crashes, seenMs)
    fresh = Model.freshCount(crashes, seenMs)
    summary = Model.summaryText(groups, crashes, days)
  }

  // Everything up to the newest crash counts as looked at.
  function markSeen() {
    var latest = Model.latestMs(crashes)
    if (latest <= seenMs) return
    seenMs = latest
    seenFile.setText(Model.serializeSeen(seenMs))
    recount()
  }

  // Omarchy's own crash-to-agent command: the same thing its crash toast
  // runs, so the diagnosis method stays in one place (the diagnose-crash skill).
  function diagnose(group) {
    if (!group) return
    var target = Model.diagnosisTarget(group)
    Quickshell.execDetached(["omarchy-agent-crash", String(target.pid), group.name, group.exe, target.signal])
  }

  function showInfo(group) {
    if (!group) return
    var pid = String(Model.diagnosisTarget(group).pid)
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.crashdesk", "bash", "-c",
      'coredumpctl info "$1" --no-pager 2>&1 | less -R', "bash", pid])
  }

  function copyReport(group) {
    if (!group) return
    Quickshell.execDetached(["wl-copy", Model.reportText(group, Date.now())])
    actionStatus = "Copied " + group.name + " report"
    actionStatusTimer.restart()
  }

  onSettingsChanged: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    running: true
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: seenFile
    path: root.stateDir + "/seen.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: { root.seenMs = Model.parseSeen(text()); root.recount() }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    onExited: function(exitCode) { root.apply(String(listStdout.text || "")) }
  }

  Process {
    id: agentProcess
    running: false
    command: ["omarchy-default-agent"]
    stdout: StdioCollector { id: agentStdout; waitForEnd: true }
    onExited: function(exitCode) { root.agentAvailable = String(agentStdout.text || "").trim() !== "" }
  }
}
