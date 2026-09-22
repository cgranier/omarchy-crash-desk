// Pure logic for Crash Desk: shaping `coredumpctl list --json=short` into
// per-program crash history. No QML imports, so it runs under node for tests.

function glyph(codePoint) {
  return String.fromCodePoint(codePoint)
}

var GLYPHS = {
  crash: glyph(0xF16A1),    // md-robot_dead, the glyph Omarchy's crash toast uses
  core: glyph(0xF0C7),      // fa-save: a core file is on disk
  noCore: glyph(0xF05E),    // fa-ban: nothing to symbolize
  closed: glyph(0xF054),    // fa-chevron-right: program folded
  open: glyph(0xF078),      // fa-chevron-down: program showing its crashes
  muted: glyph(0xF026)      // fa-volume-off
}

var SIGNALS = {
  4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 11: "SIGSEGV", 24: "SIGXCPU",
  25: "SIGXFSZ", 31: "SIGSYS"
}

function signalName(sig) {
  var n = Number(sig)
  return SIGNALS[n] || ("signal " + n)
}

function baseName(exe) {
  var value = String(exe || "")
  var slash = value.lastIndexOf("/")
  return slash === -1 ? value : value.substring(slash + 1)
}

// The first line of the helper's output is this user's uid; the rest is
// coredumpctl's JSON (or its "No coredumps found" text, or nothing).
function parseListing(raw) {
  var text = String(raw || "")
  var newline = text.indexOf("\n")
  var uid = parseInt(newline === -1 ? text : text.substring(0, newline), 10)
  var body = newline === -1 ? "" : text.substring(newline + 1).trim()
  var entries = []
  if (body.charAt(0) === "[") {
    try { entries = JSON.parse(body) } catch (e) { entries = [] }
  }
  return { uid: isFinite(uid) ? uid : -1, entries: entries }
}

// One record per crash, newest first. `time` from coredumpctl is microseconds.
function crashesFrom(entries, uid, allUsers) {
  var crashes = []
  for (var i = 0; i < (entries || []).length; i++) {
    var entry = entries[i] || {}
    if (!allUsers && uid >= 0 && Number(entry.uid) !== uid) continue
    var exe = String(entry.exe || "")
    if (exe === "") continue
    crashes.push({
      pid: Number(entry.pid) || 0,
      exe: exe,
      name: baseName(exe),
      signal: signalName(entry.sig),
      timeMs: Math.floor((Number(entry.time) || 0) / 1000),
      hasCore: String(entry.corefile || "") === "present"
    })
  }
  crashes.sort(function(a, b) { return b.timeMs - a.timeMs })
  return crashes
}

// Crash loops dump core over and over, so the unit worth showing is the
// program: how many times, how recently, which signals, and the newest crash
// that still has a core to dig into.
function groupByProgram(crashes, seenMs) {
  var byExe = {}
  var groups = []
  for (var i = 0; i < (crashes || []).length; i++) {
    var crash = crashes[i]
    var group = byExe[crash.exe]
    if (!group) {
      group = { exe: crash.exe, name: crash.name, count: 0, fresh: 0, lastMs: 0, signals: [], newest: crash, newestWithCore: null, crashes: [] }
      byExe[crash.exe] = group
      groups.push(group)
    }
    group.count += 1
    group.crashes.push(crash)
    if (crash.timeMs > (seenMs || 0)) group.fresh += 1
    if (crash.timeMs > group.lastMs) { group.lastMs = crash.timeMs; group.newest = crash }
    if (group.signals.indexOf(crash.signal) === -1) group.signals.push(crash.signal)
    if (crash.hasCore && (!group.newestWithCore || crash.timeMs > group.newestWithCore.timeMs)) group.newestWithCore = crash
  }
  groups.sort(function(a, b) { return b.lastMs - a.lastMs })
  return groups
}

// The crash a diagnosis should start from: one with a core beats a newer one
// without, because without a core there is no backtrace to read.
function diagnosisTarget(group) {
  return group.newestWithCore || group.newest
}

function freshCount(crashes, seenMs) {
  var n = 0
  for (var i = 0; i < (crashes || []).length; i++) if (crashes[i].timeMs > (seenMs || 0)) n += 1
  return n
}

function latestMs(crashes) {
  return (crashes || []).length > 0 ? crashes[0].timeMs : 0
}

function ago(timeMs, nowMs) {
  var seconds = Math.max(0, Math.floor((nowMs - timeMs) / 1000))
  if (seconds < 90) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 48) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

function groupMeta(group, nowMs) {
  var parts = []
  if (group.count > 1) parts.push("×" + group.count)
  parts.push(group.signals.join(", "))
  parts.push(ago(group.lastMs, nowMs))
  parts.push(group.newestWithCore ? "core saved" : "no core")
  return parts.join(" · ")
}

function summaryText(groups, crashes, days, mutedCount) {
  var span = rangeLabel(days)
  var suffix = mutedCount > 0 ? " · " + mutedCount + " muted" : ""
  if ((crashes || []).length === 0) return (days <= 0 ? "No crashes on record" : days === 1 ? "No crashes today" : "No crashes in " + span) + suffix
  var programs = groups.length === 1 ? "1 program" : groups.length + " programs"
  var total = crashes.length === 1 ? "1 crash" : crashes.length + " crashes"
  return programs + " · " + total + (days === 1 ? " today" : days <= 0 ? " on record" : " in " + span) + suffix
}

// Plain-text report for the clipboard: what you would paste into an issue.
function reportText(group, nowMs, frame) {
  var target = diagnosisTarget(group)
  return [
    "Program:  " + group.exe,
    "Crashes:  " + group.count + " (latest " + ago(group.lastMs, nowMs) + ")",
    "Signals:  " + group.signals.join(", "),
    "Core:     " + (group.newestWithCore ? "saved (PID " + group.newestWithCore.pid + ")" : "not saved"),
    "Where:    " + (frame || "unknown"),
    "Inspect:  coredumpctl info " + target.pid
  ].join("\n")
}

function parseSeen(raw) {
  try {
    var doc = JSON.parse(String(raw || "{}"))
    var value = Number(doc && doc.seenMs)
    return isFinite(value) && value > 0 ? value : 0
  } catch (e) {
    return 0
  }
}

function serializeSeen(seenMs) {
  return JSON.stringify({ version: 1, seenMs: seenMs }) + "\n"
}


// ---- time range ------------------------------------------------------------
// Days of history to show; -1 means everything coredumpctl still has, and 0
// (never in the cycle) means "whatever the days setting says".
var RANGES = [1, 7, 30, -1]

function rangeLabel(days) {
  if (days === 1) return "today"
  if (days <= 0) return "all time"
  return days + " days"
}

function nextRange(days) {
  var i = RANGES.indexOf(days)
  return RANGES[(i === -1 ? 0 : i + 1) % RANGES.length]
}

// ---- state file --------------------------------------------------------------
// seen.json grew from {seenMs} to {seenMs, muted, rangeDays}; an old file
// still reads.
function parseState(raw) {
  var state = { seenMs: 0, muted: [], rangeDays: 0 }
  try {
    var doc = JSON.parse(String(raw || "{}")) || {}
    var seen = Number(doc.seenMs)
    if (isFinite(seen) && seen > 0) state.seenMs = seen
    if (Array.isArray(doc.muted)) {
      for (var i = 0; i < doc.muted.length; i++) {
        var exe = String(doc.muted[i] || "")
        if (exe !== "" && state.muted.indexOf(exe) === -1) state.muted.push(exe)
      }
    }
    var range = Number(doc.rangeDays)
    if (RANGES.indexOf(range) !== -1 || range === 0) state.rangeDays = range
  } catch (e) {}
  return state
}

function serializeState(state) {
  return JSON.stringify({ version: 2, seenMs: state.seenMs || 0, muted: state.muted || [], rangeDays: state.rangeDays || 0 }) + "\n"
}

// A muted program stays in the history but out of the count, the bar and the
// main list.
function splitMuted(groups, muted) {
  var shown = []
  var hidden = []
  for (var i = 0; i < (groups || []).length; i++) {
    ((muted || []).indexOf(groups[i].exe) === -1 ? shown : hidden).push(groups[i])
  }
  return { shown: shown, hidden: hidden }
}

// ---- why it crashed ------------------------------------------------------------
// systemd-coredump writes the backtrace into the journal at dump time, so
// `coredumpctl info` has a stack even after the core file itself is gone.
// The first frame is nearly always the raise/abort plumbing; the answer is
// the first frame with a name after that.
var PLUMBING = /^(n\/a|raise|abort|__GI_raise|__GI_abort|__pthread_kill_implementation|__pthread_kill_internal|pthread_kill|gsignal|__libc_start_call_main|__libc_start_main)$/

function topFrame(infoText) {
  var lines = String(infoText || "").split("\n")
  var inTrace = false
  var fallback = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/Stack trace of thread/.test(line)) { if (inTrace) break; inTrace = true; continue }
    if (!inTrace) continue
    var m = /#\d+\s+0x[0-9a-f]+\s+(.+?)\s+\(([^()]+?)(?:\s*\+\s*0x[0-9a-f]+)?\)\s*$/.exec(line)
    if (!m) { if (line.trim() === "") break; continue }
    // A demangled C++ name carries its argument list; the name is enough.
    var symbol = m[1].replace(/\(.*$/, "").trim()
    var lib = m[2]
    if (fallback === "") fallback = "in " + lib
    if (PLUMBING.test(symbol)) continue
    return "in " + symbol + " (" + lib + ")"
  }
  return fallback
}

function crashMeta(crash, frame, nowMs) {
  var parts = [ago(crash.timeMs, nowMs), crash.signal, "PID " + crash.pid, crash.hasCore ? "core saved" : "no core"]
  if (frame) parts.push(frame)
  return parts.join(" · ")
}

// ---- rows --------------------------------------------------------------------
// Programs, each optionally opened to show its crashes; muted programs
// under their own header at the end. `cursorIndex` numbers what the cursor
// can land on.
function buildRows(shown, hidden, expanded) {
  var rows = []
  var cursorIndex = 0
  function program(group, muted) {
    var open = !muted && (expanded || []).indexOf(group.exe) !== -1
    rows.push({ type: "group", group: group, muted: muted, open: open, cursorIndex: cursorIndex })
    cursorIndex += 1
    if (!open) return
    for (var c = 0; c < (group.crashes || []).length; c++) {
      rows.push({ type: "crash", group: group, crash: group.crashes[c], cursorIndex: cursorIndex })
      cursorIndex += 1
    }
  }
  for (var i = 0; i < (shown || []).length; i++) program(shown[i], false)
  if ((hidden || []).length > 0) {
    rows.push({ type: "header", text: "MUTED · " + hidden.length })
    for (var h = 0; h < hidden.length; h++) program(hidden[h], true)
  }
  return rows
}

function cursorRows(rows) {
  var out = []
  for (var i = 0; i < (rows || []).length; i++) if (rows[i].cursorIndex !== undefined) out.push(rows[i])
  return out
}

// ---- agents ------------------------------------------------------------------
// The agents Omarchy itself knows (omarchy-default-agent), in its order.
var AGENTS = [
  ["claude", "Claude Code"], ["codex", "Codex"], ["grok", "Grok"], ["gemini", "Gemini"], ["opencode", "OpenCode"],
  ["copilot", "Copilot"], ["cursor-agent", "Cursor"], ["crush", "Crush"], ["muse", "Muse"], ["hermes", "Hermes"],
  ["pi", "Pi"], ["omp", "Oh My Pi"], ["openclaw", "OpenClaw"]
]

function agentName(id) {
  for (var i = 0; i < AGENTS.length; i++) if (AGENTS[i][0] === id) return AGENTS[i][1]
  return id
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPHS: GLYPHS, signalName: signalName, baseName: baseName, parseListing: parseListing,
    crashesFrom: crashesFrom, groupByProgram: groupByProgram, diagnosisTarget: diagnosisTarget,
    freshCount: freshCount, latestMs: latestMs, ago: ago, groupMeta: groupMeta, summaryText: summaryText,
    reportText: reportText, parseSeen: parseSeen, serializeSeen: serializeSeen,
    RANGES: RANGES, rangeLabel: rangeLabel, nextRange: nextRange, parseState: parseState, serializeState: serializeState,
    splitMuted: splitMuted, topFrame: topFrame, crashMeta: crashMeta, buildRows: buildRows, cursorRows: cursorRows,
    AGENTS: AGENTS, agentName: agentName
  }
}
