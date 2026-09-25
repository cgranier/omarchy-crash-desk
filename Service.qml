import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads systemd-coredump's history and remembers how far you have looked,
// which programs you have muted, and how far back you like to see.
Item {
  id: root

  property var settings: ({})

  property var crashes: []
  property var groups: []        // programs shown
  property var mutedGroups: []   // programs muted, kept for the footer
  property int fresh: 0
  property double seenMs: 0
  property var muted: []
  property int rangeDays: 0      // 0 = the `days` setting's window
  property var frames: ({})      // pid -> "in symbol (lib)", from coredumpctl info
  property double now: Date.now()
  property string summary: "Checking…"
  property bool agentAvailable: false
  property string defaultAgent: ""
  property var installedAgents: []
  property bool loaded: false
  property string actionStatus: ""

  readonly property int days: intSetting("days", 14, 1, 90)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 15, 3600)
  readonly property bool allUsers: setting("allUsers", false) === true
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-crashdesk"
  readonly property string agentScript: String(Qt.resolvedUrl("bin/crashdesk-agent")).replace(/^file:\/\//, "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // The window in effect: the setting, unless a range was picked in the panel.
  function windowDays() { return rangeDays === 0 ? days : rangeDays }

  function refresh() {
    if (listProcess.running) return
    // The uid rides along on the first line so crashes can be filtered to this
    // user. coredumpctl exits 1 with "No coredumps found" when the window is
    // empty, which is an answer, not a failure. "All time" passes no --since.
    var since = windowDays() > 0 ? "--since=-" + windowDays() + "days" : ""
    listProcess.command = ["timeout", "15", "sh", "-c", 'id -u; coredumpctl list --json=short --no-pager $1 2>/dev/null; exit 0', "sh", since]
    listProcess.running = true
    if (!agentProcess.running) agentProcess.running = true
  }

  function apply(raw) {
    var parsed = Model.parseListing(raw)
    crashes = Model.crashesFrom(parsed.entries, parsed.uid, allUsers)
    recount()
    loaded = true
    queueFrames()
  }

  function recount() {
    now = Date.now()
    var split = Model.splitMuted(Model.groupByProgram(crashes, seenMs), muted)
    groups = split.shown
    mutedGroups = split.hidden
    var visible = []
    for (var i = 0; i < crashes.length; i++) if (muted.indexOf(crashes[i].exe) === -1) visible.push(crashes[i])
    fresh = Model.freshCount(visible, seenMs)
    summary = Model.summaryText(groups, visible, windowDays(), mutedGroups.length)
  }

  // The state file is never opened by the shell: bin/crashdesk-state checks
  // the directory chain, refuses links, FIFOs and oversized files, and writes
  // atomically. Writes are serialised; one made while another runs waits.
  readonly property string stateScript: String(Qt.resolvedUrl("bin/crashdesk-state")).replace(/^file:\/\//, "")
  property string pendingWrite: ""

  function saveState() {
    pendingWrite = Model.serializeState({ seenMs: seenMs, muted: muted, rangeDays: rangeDays })
    if (!writeProcess.running) flushWrite()
  }

  function flushWrite() {
    if (pendingWrite === "") return
    writeProcess.command = ["timeout", "10", "/usr/bin/python3", stateScript, "write", stateDir + "/seen.json", pendingWrite]
    pendingWrite = ""
    writeProcess.running = true
  }

  // Everything up to the newest crash counts as looked at.
  function markSeen() {
    var latest = Model.latestMs(crashes)
    if (latest <= seenMs) return
    seenMs = latest
    saveState()
    recount()
  }

  function toggleMute(group) {
    if (!group) return
    var next = muted.filter(function(exe) { return exe !== group.exe })
    var nowMuted = next.length === muted.length
    if (nowMuted) next.push(group.exe)
    muted = next
    saveState()
    recount()
    say((nowMuted ? "Muted " : "Unmuted ") + group.name)
  }

  // today → 7 days → 30 days → all time → today…
  function cycleRange() {
    rangeDays = Model.nextRange(windowDays())
    saveState()
    refresh()
  }

  function say(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // ---- why it crashed -------------------------------------------------------
  // One `coredumpctl info` per crash, one at a time, newest first. The
  // backtrace lives in the journal, so this works after the core is gone.
  property var frameQueue: []

  function queueFrames() {
    var wanted = []
    for (var i = 0; i < crashes.length && wanted.length < 40; i++) {
      if (frames[crashes[i].pid] === undefined) wanted.push(crashes[i].pid)
    }
    frameQueue = wanted
    nextFrame()
  }

  function nextFrame() {
    if (infoProcess.running || frameQueue.length === 0) return
    var pid = frameQueue[0]
    frameQueue = frameQueue.slice(1)
    infoProcess.pid = pid
    // c++filt (binutils) turns _ZSt21__glibcxx_assert_fail… into a name a
    // person can read; without it the mangled name is shown as is.
    infoProcess.command = ["timeout", "10", "sh", "-c",
      'coredumpctl info "$1" --no-pager 2>/dev/null | { command -v c++filt >/dev/null 2>&1 && c++filt || cat; }', "sh", String(pid)]
    infoProcess.running = true
  }

  function frameFor(crash) {
    var f = crash ? frames[crash.pid] : undefined
    return f === undefined ? "" : f
  }

  // ---- actions --------------------------------------------------------------
  // Only the PID goes to the agent: names and paths in a crash record are
  // chosen by whatever crashed, so the agent reads the record itself as data.
  // The method stays in one place, Omarchy's diagnose-crash skill.
  function diagnose(group, crash) {
    diagnoseWith("default", group, crash)
  }

  // The same brief, handed to an agent you name instead of the default.
  function diagnoseWith(agent, group, crash) {
    if (!group || !agent) return
    var target = crash || Model.diagnosisTarget(group)
    var command = ["bash", agentScript, agent, String(target.pid)]
    if (setting("autoApprove", false) === true) command.push("--auto-approve")
    Quickshell.execDetached(command)
  }

  function showInfo(group, crash) {
    if (!group) return
    var pid = String((crash || Model.diagnosisTarget(group)).pid)
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.crashdesk", "bash", "-c",
      'coredumpctl info "$1" --no-pager 2>&1 | less -R', "bash", pid])
  }

  function copyReport(group) {
    if (!group) return
    Quickshell.execDetached(["wl-copy", Model.reportText(group, Date.now(), frameFor(Model.diagnosisTarget(group)))])
    say("Copied " + group.name + " report")
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
    id: readProcess
    running: true
    command: ["timeout", "10", "/usr/bin/python3", root.stateScript, "read", root.stateDir + "/seen.json"]
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    onExited: function(exitCode) {
      // A refused or missing file means a fresh start; nothing is written
      // over it until the person does something that changes state.
      var state = Model.parseState(exitCode === 0 ? readOut.text : "{}")
      root.seenMs = state.seenMs
      root.muted = state.muted
      root.rangeDays = state.rangeDays
      root.recount()
      root.refresh()
    }
  }

  Process {
    id: writeProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) root.say("Could not save Crash Desk's state")
      root.flushWrite()
    }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    onExited: function(exitCode) { root.apply(String(listStdout.text || "")) }
  }

  Process {
    id: infoProcess
    property int pid: 0
    running: false
    command: []
    stdout: StdioCollector { id: infoStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var next = {}
      for (var key in root.frames) next[key] = root.frames[key]
      next[pid] = Model.topFrame(String(infoStdout.text || ""))
      root.frames = next
      root.nextFrame()
    }
  }

  // Which agent is default, and which of Omarchy's known agents are installed.
  Process {
    id: agentProcess
    running: false
    command: ["timeout", "10", "sh", "-c", 'omarchy-default-agent 2>/dev/null; echo; for a in "$@"; do command -v "$a" >/dev/null 2>&1 && echo "$a"; done; exit 0', "sh",
      "claude", "codex", "grok", "gemini", "opencode", "copilot", "cursor-agent", "crush", "muse", "hermes", "pi", "omp"]
    stdout: StdioCollector { id: agentStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var lines = String(agentStdout.text || "").split("\n")
      root.defaultAgent = (lines[0] || "").trim()
      root.agentAvailable = root.defaultAgent !== ""
      var found = []
      for (var i = 1; i < lines.length; i++) if (lines[i].trim() !== "") found.push(lines[i].trim())
      root.installedAgents = found
    }
  }
}
