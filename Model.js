function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states, thresholdEnabled) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery && thresholdEnabled === true)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states, thresholdEnabled) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states, thresholdEnabled)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states, thresholdEnabled) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states, thresholdEnabled)) return "Threshold"
  if (onBattery) return "On battery"
  if (d.state === states.FullyCharged || percentage >= 1) return "Fully charged"
  return "Charging"
}

// ---- Charge-threshold toggle. This calls UPower's own
// EnableChargeThreshold DBus method (UPower ships its own polkit policy for
// it), not a raw sysfs write -- see Panel.qml for the full reasoning.
// `gdbus call` prints a boolean property read as "(<true>,)" / "(<false>,)".
function parseGdbusBoolean(raw) {
  var text = String(raw || "")
  if (text.indexOf("true") !== -1) return true
  if (text.indexOf("false") !== -1) return false
  return null
}

// ---- Quick Dim / Travel Mode brightness. "40%" / "40" -> 40, or null on
// anything that doesn't parse (no laptop panel connected, DDC failure,
// etc.) -- callers skip the brightness leg of the preset rather than
// saving/restoring a bogus value.
function parseBrightnessPercent(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "").replace(/%$/, "")
  var value = parseInt(text, 10)
  if (!isFinite(value) || value < 0 || value > 100) return null
  return value
}

// ---- Travel Mode monitor refresh rate. Rebuilds the `hyprctl keyword
// monitor` argument for one monitor with only the refresh rate changed,
// from a `hyprctl monitors -j` entry -- resolution, position, and scale
// round-trip unchanged so this can't accidentally move or resize anything.
function monitorKeywordLine(monitorInfo, refreshRate) {
  var m = monitorInfo || {}
  var rate = refreshRate || m.refreshRate
  return m.name + "," + m.width + "x" + m.height + "@" + rate
    + "," + m.x + "x" + m.y + "," + m.scale
}

// ---- Watts drain history: a short in-memory sparkline, not a database.
function parseWattsRate(rateText) {
  var value = parseFloat(String(rateText || ""))
  return isFinite(value) ? value : null
}

// The sampler emits one TSV row per grouped application: display name, CPU
// percentage, and impact band. This remains an estimate because Linux exposes
// whole-system battery watts, not trustworthy per-process watt meters.
function parsePowerImpact(raw) {
  var rows = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 3 || !parts[0]) continue
    var cpu = parseFloat(parts[1])
    if (!isFinite(cpu)) continue
    rows.push({ name: parts[0], cpu: cpu, impact: parts[2] })
  }
  return rows
}

function parseBatteryTemperature(raw) {
  var value = parseFloat(String(raw || "").trim())
  return isFinite(value) && value >= -20 && value <= 100 ? value : null
}

// Appends one sample and drops anything older than maxAgeSeconds -- a
// fixed-size rolling window instead of an ever-growing array.
function appendDrainSample(samples, watts, now, maxAgeSeconds) {
  var next = (samples || []).slice()
  if (watts !== null) next.push({ t: now, w: watts })
  var cutoff = now - maxAgeSeconds
  while (next.length > 0 && next[0].t < cutoff) next.shift()
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    parseGdbusBoolean: parseGdbusBoolean,
    parseBrightnessPercent: parseBrightnessPercent,
    monitorKeywordLine: monitorKeywordLine,
    parseWattsRate: parseWattsRate,
    parsePowerImpact: parsePowerImpact,
    parseBatteryTemperature: parseBatteryTemperature,
    appendDrainSample: appendDrainSample
  }
}
