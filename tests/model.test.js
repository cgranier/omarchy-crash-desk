// Run with: node tests/model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const M = require("../Model.js")

const raw = fs.readFileSync(path.join(__dirname, "fixtures", "listing.txt"), "utf8")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

test("parseListing splits uid from JSON and survives junk", () => {
  const parsed = M.parseListing(raw)
  assert.strictEqual(parsed.uid, 1000)
  assert.strictEqual(parsed.entries.length, 6)
  assert.deepStrictEqual(M.parseListing("1000\nNo coredumps found.\n"), { uid: 1000, entries: [] })
  assert.deepStrictEqual(M.parseListing("1000"), { uid: 1000, entries: [] })
  assert.deepStrictEqual(M.parseListing("1000\n[{broken"), { uid: 1000, entries: [] })
  assert.deepStrictEqual(M.parseListing(""), { uid: -1, entries: [] })
})

const parsed = M.parseListing(raw)
const crashes = M.crashesFrom(parsed.entries, parsed.uid, false)

test("crashesFrom keeps this user's crashes, newest first", () => {
  assert.deepStrictEqual(crashes.map((c) => c.pid), [202, 201, 200, 100])
  assert.deepStrictEqual(crashes[0], { pid: 202, exe: "/usr/bin/mediad", name: "mediad", signal: "SIGSEGV", timeMs: 2000120000, hasCore: false })
  assert.strictEqual(crashes[3].signal, "SIGILL")
  assert.deepStrictEqual(M.crashesFrom(parsed.entries, parsed.uid, true).map((c) => c.pid), [300, 202, 201, 200, 100])
  assert.strictEqual(M.signalName(99), "signal 99")
})

test("groupByProgram folds crash loops and tracks the best core", () => {
  const groups = M.groupByProgram(crashes, 2000060000)
  assert.deepStrictEqual(groups.map((g) => g.name), ["mediad", "vault"])
  const mediad = groups[0]
  assert.strictEqual(mediad.count, 3)
  assert.strictEqual(mediad.fresh, 1)                       // only pid 202 is newer than seenMs
  assert.deepStrictEqual(mediad.signals, ["SIGSEGV", "SIGABRT"])
  assert.strictEqual(mediad.newest.pid, 202)
  assert.strictEqual(M.diagnosisTarget(mediad).pid, 201)    // the one with a core wins
  assert.strictEqual(M.diagnosisTarget(groups[1]).pid, 100) // no core anywhere: newest
  assert.strictEqual(M.freshCount(crashes, 2000060000), 1)
  assert.strictEqual(M.freshCount(crashes, 0), 4)
  assert.strictEqual(M.latestMs(crashes), 2000120000)
  assert.strictEqual(M.latestMs([]), 0)
})

test("text helpers", () => {
  const now = 2000120000 + 3 * 3600 * 1000
  const groups = M.groupByProgram(crashes, 0)
  assert.strictEqual(M.ago(now - 30000, now), "just now")
  assert.strictEqual(M.ago(now - 5 * 60000, now), "5m ago")
  assert.strictEqual(M.ago(now - 47 * 3600000, now), "47h ago")
  assert.strictEqual(M.ago(now - 72 * 3600000, now), "3d ago")
  assert.strictEqual(M.groupMeta(groups[0], now), "×3 · SIGSEGV, SIGABRT · 3h ago · core saved")
  assert.ok(/^SIGILL · \d+d ago · no core$/.test(M.groupMeta(groups[1], now)))
  assert.strictEqual(M.summaryText(groups, crashes, 14), "2 programs · 4 crashes in 14 days")
  assert.strictEqual(M.summaryText([], [], 14), "No crashes in 14 days")
  assert.strictEqual(M.summaryText([groups[1]], [crashes[3]], 7), "1 program · 1 crash in 7 days")
  const report = M.reportText(groups[0], now)
  assert.ok(report.includes("Program:  /usr/bin/mediad"))
  assert.ok(report.includes("Core:     saved (PID 201)"))
  assert.ok(report.includes("coredumpctl info 201"))
})

test("seen state round-trips", () => {
  assert.strictEqual(M.parseSeen(M.serializeSeen(12345)), 12345)
  assert.strictEqual(M.parseSeen("nope"), 0)
  assert.strictEqual(M.parseSeen('{"seenMs":-5}'), 0)
})

const groups = M.groupByProgram(crashes, 0)

test("state file: v1 seen.json still reads, v2 round-trips, junk is ignored", () => {
  assert.deepStrictEqual(M.parseState('{"version":1,"seenMs":5}'), { seenMs: 5, muted: [], rangeDays: 0 })
  const state = { seenMs: 9, muted: ["/usr/bin/mediad", "/usr/bin/mediad", ""], rangeDays: 7 }
  assert.deepStrictEqual(M.parseState(M.serializeState(state)), { seenMs: 9, muted: ["/usr/bin/mediad"], rangeDays: 7 })
  assert.deepStrictEqual(M.parseState('{"rangeDays": 12, "muted": "x"}').rangeDays, 0)
  assert.deepStrictEqual(M.parseState('{"rangeDays": -1}').rangeDays, -1)
  assert.deepStrictEqual(M.parseState("nope"), { seenMs: 0, muted: [], rangeDays: 0 })
})

test("ranges cycle today → 7 → 30 → all → today, and a setting outside the cycle starts at today", () => {
  assert.deepStrictEqual([1, 7, 30, -1, 14].map(M.nextRange), [7, 30, -1, 1, 1])
  assert.deepStrictEqual([1, 7, 30, -1, 0].map(M.rangeLabel), ["today", "7 days", "30 days", "all time", "all time"])
  assert.strictEqual(M.summaryText(groups, crashes, 1, 0), "2 programs · 4 crashes today")
  assert.strictEqual(M.summaryText(groups, crashes, -1, 1), "2 programs · 4 crashes on record · 1 muted")
  assert.strictEqual(M.summaryText([], [], 30, 0), "No crashes in 30 days")
})

test("muting hides a program from the count but keeps it for the footer", () => {
  const split = M.splitMuted(groups, ["/usr/bin/mediad"])
  assert.deepStrictEqual([split.shown.map((g) => g.name), split.hidden.map((g) => g.name)], [["vault"], ["mediad"]])
  assert.deepStrictEqual(M.splitMuted(groups, []).hidden, [])
})

test("topFrame skips the abort plumbing and survives a missing trace", () => {
  const info = [
    "       Message: Process 262681 (cam) of user 1000 dumped core.",
    "                Stack trace of thread 262681:",
    "                #0  0x000076746409a17c n/a (libc.so.6 + 0x9a17c)",
    "                #1  0x000076746403e5d0 raise (libc.so.6 + 0x3e5d0)",
    "                #2  0x0000767464025685 abort (libc.so.6 + 0x25685)",
    "                #3  0x000076746449d5bd _ZSt21__glibcxx_assert_failPKciS0_S0_ (libstdc++.so.6 + 0x9d5bd)",
    "                Stack trace of thread 262682:",
    "                #0  0x00007674640a0952 poll_me (libc.so.6 + 0xa0952)"
  ].join("\n")
  assert.strictEqual(M.topFrame(info), "in _ZSt21__glibcxx_assert_failPKciS0_S0_ (libstdc++.so.6)")
  const onlyPlumbing = "Stack trace of thread 1:\n #0 0x1 n/a (libfoo.so + 0x1)\n #1 0x2 raise (libc.so.6 + 0x2)\n"
  assert.strictEqual(M.topFrame(onlyPlumbing), "in libfoo.so")
  assert.strictEqual(M.topFrame("Message: no trace here"), "")
  assert.strictEqual(M.topFrame(""), "")
})

test("rows: programs fold and open, crashes sit under their program, muted ones come last", () => {
  const rows = M.buildRows(groups, [], [])
  assert.deepStrictEqual(rows.map((r) => r.type), ["group", "group"])
  const open = M.buildRows(groups, [], ["/usr/bin/mediad"])
  assert.deepStrictEqual(open.map((r) => r.type + ":" + (r.cursorIndex)), ["group:0", "crash:1", "crash:2", "crash:3", "group:4"])
  assert.strictEqual(open[1].crash.pid, 202)
  const withMuted = M.buildRows([groups[1]], [groups[0]], ["/usr/bin/mediad"])
  assert.deepStrictEqual(withMuted.map((r) => r.type), ["group", "header", "group"])
  assert.strictEqual(withMuted[1].text, "MUTED · 1")
  assert.strictEqual(withMuted[2].muted, true)
  assert.strictEqual(M.cursorRows(withMuted).length, 2)
  assert.strictEqual(M.crashMeta(crashes[0], "in x (y)", 2000120000 + 5000), "just now · SIGSEGV · PID 202 · no core · in x (y)")
})

test("agents: names for Omarchy's known ids", () => {
  assert.strictEqual(M.agentName("cursor-agent"), "Cursor")
  assert.strictEqual(M.agentName("whatever"), "whatever")
  assert.ok(M.reportText(groups[0], 0, "in f (g)").indexOf("Where:    in f (g)") !== -1)
})

console.log("\n" + passed + " tests passed")
