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

console.log("\n" + passed + " tests passed")
