const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const { parseChargeThreshold, validAsusChargeLimit } = require("../Model.js")

for (const enabled of [true, false]) {
  assert.deepEqual(parseChargeThreshold(`backend\tupower\nenabled\t${enabled}\nlimit\t0\n`),
    { backend: "upower", enabled, limit: 0 })
}
for (const limit of [20, 55, 80, 99, 100]) {
  assert.deepEqual(parseChargeThreshold(`backend\tasus\nenabled\t${limit < 100}\nlimit\t${limit}\n`),
    { backend: "asus", enabled: limit < 100, limit })
}
for (const raw of ["", "backend\tnone\n", "(<true>,)",
  "backend\tasus\nenabled\ttrue\nlimit\t100",
  "backend\tasus\nenabled\tfalse\nlimit\t80",
  "backend\tasus\nenabled\ttrue\nlimit\t19",
  "backend\tasus\nenabled\ttrue\nlimit\t80; echo unsafe",
  "backend\t<img src='https://example.invalid/tracker'>\nenabled\ttrue"]) {
  assert.deepEqual(parseChargeThreshold(raw), { backend: "none", enabled: false, limit: 0 })
}
for (const limit of [20, 55, 80, 99]) assert.equal(validAsusChargeLimit(limit), limit)
for (const limit of [0, 19, 100, 101, 80.5, "80", true, null, NaN, Infinity])
  assert.equal(validAsusChargeLimit(limit), 0)

// Exercise the QML state handler itself, including the persisted setting.
const panel = fs.readFileSync(require.resolve("../Panel.qml"), "utf8")
const handler = panel.match(/^  function updateChargeThreshold\(raw\) \{[\s\S]*?^  \}/m)[0]
const settingsWrites = []
const context = vm.createContext({
  Model: require("../Model.js"),
  root: {
    settings: {}, moduleName: "io.github.aryan-techie.battery",
    bar: { shell: { updateEntryInline: (id, settings) => settingsWrites.push({ ...settings }) } }
  }
})
Object.defineProperty(context, "asusChargeLimit", {
  get: () => validAsusChargeLimit(context.root.settings.asusChargeLimit)
})
vm.runInContext(handler, context)
context.updateChargeThreshold("backend\tasus\nenabled\ttrue\nlimit\t55")
assert.equal(context.asusChargeLimit, 55)
context.updateChargeThreshold("backend\tasus\nenabled\tfalse\nlimit\t100")
assert.equal(context.asusChargeLimit, 55, "one-shot must not overwrite the saved limit")
// Simulate the state reloaded by a fresh widget after a shell restart.
context.root.settings = JSON.parse(JSON.stringify(settingsWrites.at(-1)))
context.updateChargeThreshold("backend\tasus\nenabled\tfalse\nlimit\t100")
assert.equal(context.asusChargeLimit, 55)
context.updateChargeThreshold("backend\tasus\nenabled\ttrue\nlimit\t55")
assert.equal(settingsWrites.length, 1, "unchanged reads must not rewrite shell.json")
context.updateChargeThreshold("backend\tasus\nenabled\ttrue\nlimit\t80")
assert.equal(context.asusChargeLimit, 80, "adopt a normal limit changed by another client")
context.root.settings = {}
context.updateChargeThreshold("backend\tasus\nenabled\tfalse\nlimit\t100")
assert.equal(context.asusChargeLimit, 0, "never invent a restore limit on first run at 100%")
console.log("Charge threshold model tests passed")
