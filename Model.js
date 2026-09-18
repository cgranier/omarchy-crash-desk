// Pure logic for Crash Desk: shaping `coredumpctl list --json=short` into
// per-program crash history. No QML imports, so it runs under node for tests.

function glyph(codePoint) {
  return String.fromCodePoint(codePoint)
}

var GLYPHS = {
  crash: glyph(0xF16A1),    // md-robot_dead, the glyph Omarchy's crash toast uses
  core: glyph(0xF0C7),      // fa-save: a core file is on disk
  noCore: glyph(0xF05E)     // fa-ban: nothing to symbolize
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
      group = { exe: crash.exe, name: crash.name, count: 0, fresh: 0, lastMs: 0, signals: [], newest: crash, newestWithCore: null }
      byExe[crash.exe] = group
      groups.push(group)
    }
    group.count += 1
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

function summaryText(groups, crashes, days) {
  if ((crashes || []).length === 0) return "No crashes in " + days + " days"
  var programs = groups.length === 1 ? "1 program" : groups.length + " programs"
  var total = crashes.length === 1 ? "1 crash" : crashes.length + " crashes"
  return programs + " · " + total + " in " + days + " days"
}

// Plain-text report for the clipboard: what you would paste into an issue.
function reportText(group, nowMs) {
  var target = diagnosisTarget(group)
  return [
    "Program:  " + group.exe,
    "Crashes:  " + group.count + " (latest " + ago(group.lastMs, nowMs) + ")",
    "Signals:  " + group.signals.join(", "),
    "Core:     " + (group.newestWithCore ? "saved (PID " + group.newestWithCore.pid + ")" : "not saved"),
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPHS: GLYPHS, signalName: signalName, baseName: baseName, parseListing: parseListing,
    crashesFrom: crashesFrom, groupByProgram: groupByProgram, diagnosisTarget: diagnosisTarget,
    freshCount: freshCount, latestMs: latestMs, ago: ago, groupMeta: groupMeta, summaryText: summaryText,
    reportText: reportText, parseSeen: parseSeen, serializeSeen: serializeSeen
  }
}
