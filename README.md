<div align="center">

# Better Battery for Omarchy

**An enhanced power/battery bar widget for [Omarchy](https://omarchy.org/) — everything the built-in Power widget does, plus a charge-threshold toggle, Quick Dim, Travel Mode, hybrid-GPU status, and a live power-draw history.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FAROICE-HQ%2Fomarchy-battery%2Fmain%2Fmanifest.json&query=%24.version&label=version&color=informational)](manifest.json)
[![Omarchy plugin](https://img.shields.io/badge/omarchy-plugin-6d4aff)](https://omarchy.org/)

*Part of [OMARCHY100](https://github.com/AROICE-HQ/omarchy100) — a 100-plugin suite for Omarchy.*

[Features](#features) • [Install](#install) • [Usage](#usage) • [How it works](#how-it-works)

</div>

Omarchy's built-in Power widget is already solid: battery percentage, an
animated charge bar, size/cycles/time/rate stats, and a power-profile
picker. This plugin clones that code as-is and adds five things aimed
specifically at laptops: a real charge-threshold toggle, a one-click dim,
a travel preset, hybrid-GPU status, and a short power-draw history —
inspired by `laptop-power-center` and `battery-usage` on the marketplace.

It installs as its own independent plugin — both it and the built-in
widget can be enabled at once, so you can compare them side by side before
deciding which stays on your bar.

![Better Battery panel — stats, power profile, charge threshold, quick actions, GPU status, and power draw history](preview.png)

## Contents

- [Features](#features)
- [Install](#install)
- [Usage](#usage)
- [How it works](#how-it-works)
- [External dependencies](#external-dependencies)
- [Uninstalling](#uninstalling)
- [Changelog](#changelog)
- [License](#license)
- [Author](#author)

## Features

Everything the built-in `omarchy.power` already has:

- Battery percentage with an animated charge bar and status icon.
- Battery size, charge cycles, time to full/empty, charge rate.
- Charge-threshold *detection* — shows "Holding" when firmware-level charge
  protection is already active.
- Power-profile picker (power-saver / balanced / performance).

New in this plugin:

- **Charge-threshold toggle** — turns firmware-backed charge protection on
  or off, at whatever start/end percentages your hardware already reports.
  Prefers UPower's own `EnableChargeThreshold` method and falls back to
  the ASUS `asusd` daemon when UPower cannot control the limit. Never
  writes sysfs directly. Only shown when a supported backend is detected.
- **Quick Dim** — one click drops your laptop panel to 40% brightness;
  click again to restore the exact value it was at. Reads the current
  brightness first, so a setup with no laptop panel active (docked to an
  external monitor, say) just does nothing rather than guessing.
- **Travel Mode** — bundles power profile, brightness, and this monitor's
  refresh rate into one save/restore pair: switches to power-saver, dims
  to 40%, and caps refresh to 60Hz, then puts all three back exactly as
  they were. Session-only — nothing here persists past a restart.
- **GPU status** — power draw and utilization for the discrete GPU, shown
  only on hybrid-graphics laptops (detected via Omarchy's own `omarchy hw
  hybrid gpu`). Status only, no mode switching — nothing here would ever
  need a logout/reboot to take effect.
- **Power draw history** — a short in-memory sparkline of the last 10
  minutes' draw, plus a live watts readout. No database, no persistence;
  it's gone the moment the shell restarts.
- **Power impact** — ranks the three busiest applications from a recent
  one-second CPU sample, grouped by process name. It samples only while the
  panel is open and labels the result as an estimate rather than pretending
  Linux exposes exact per-application watts.
- **Battery temperature** — shows the battery's real temperature sensor when
  the hardware exposes it through Linux's power-supply interface.

## Install

```
omarchy plugin add https://github.com/AROICE-HQ/omarchy-battery.git --enable
```

Or, to develop/inspect it locally first:

```
omarchy plugin clone io.github.aryan-techie.battery --edit
```

(swap in this repo's contents, or copy this folder to
`~/.config/omarchy/plugins/io.github.aryan-techie.battery/` directly and
run `omarchy-shell shell rescanPlugins` if it doesn't pick up right away).

## Usage

Everything from the built-in widget works the same way — click the bar
pill to open the panel, click a profile pill to switch it.

- **Charge threshold**: flip the toggle under Power Profile. Only appears
  if your hardware supports it.
  On ASUS laptops managed by `asusd`, switching it off requests a one-shot
  full charge, and switching it on restores your previous limit.
  The plugin saves that limit in its bar settings across shell
  restarts. If it first sees your battery already set to 100%, set your
  normal limit with `asusctl` and reopen the panel before using the toggle;
  the plugin never guesses a protection percentage.
  ASUS normally restores the limit on unplug, but affected `asusd` versions
  have a [known restoration bug](https://github.com/OpenGamingCollective/asusctl/issues/439).
  Check the toggle afterward and turn protection back on manually if needed.
- **Quick Dim** / **Travel Mode**: one click each in Quick Actions; click
  again to undo. Both are safe to leave on indefinitely — closing the
  panel or restarting the shell doesn't lose the saved state, only a
  restart of the whole session does (by design — these are meant to be
  short-lived, not permanent settings).
- **GPU** and **power draw** sections need no interaction; they just show
  what's currently true.

## How it works

- **Charge threshold** uses `busctl` to talk to the system D-Bus. The
  helper picks the first system battery listed by `upower -e`, checks
  `ChargeThresholdSupported`, and reads `ChargeThresholdEnabled`. The
  toggle calls `EnableChargeThreshold` with the requested state. The panel
  displays the UPower percentages from `omarchy-battery-status --shell`.
  If UPower lacks charge control, the helper looks for a running `asusd`
  that advertises `ChargeControlEndThreshold`. The panel displays this
  live ASUS limit. The helper calls `OneShotFullCharge()` for a full charge,
  uses the property setter to restore the saved limit, and reads the ASUS
  limit back after either action. The panel reports failed actions and
  refreshes the toggle from the daemon.
- **Quick Dim / Travel Mode brightness**: `omarchy brightness display
  --monitor eDP-2`, read before changing (to know what to restore) and
  written after. A read that can't resolve a number — no internal panel
  currently active — means the brightness leg of either feature is
  skipped, not guessed at.
- **Travel Mode refresh rate**: `hyprctl monitors -j` to read the focused
  monitor's current mode, then `hyprctl keyword monitor` to reapply it
  with only the refresh rate changed — resolution, position, and scale
  always round-trip untouched.
- **GPU status**: `omarchy hw hybrid gpu` gates visibility;
  `nvidia-smi --query-gpu=power.draw,utilization.gpu` supplies the numbers
  when present.
- **Power draw history**: reuses the `rate` field already in every
  `omarchy-battery-status --shell` sample (the same one the built-in
  widget's stats row shows as text) and keeps a rolling 10-minute window
  of it in memory — no new subprocess, no database.
- **Power impact**: `power-impact.sh` reads per-process CPU counters twice,
  one second apart, groups the deltas by application name, and returns the
  three busiest groups. It runs only while the panel is open. CPU activity is
  a useful power proxy, not a per-application watt measurement.
- **Battery temperature**: `battery-temperature.sh` reads the first available
  `BAT*/temp` sensor, converts the Linux tenths-of-a-degree value to Celsius,
  and emits nothing on unsupported hardware so the row stays hidden.
- **Settings**: charge threshold reflects live hardware state. The ASUS
  fallback saves `asusChargeLimit` in the widget's settings for manual
  restoration after a shell restart. Quick Dim/Travel Mode are
  session-only toggles; GPU status and power draw are live/derived.

## External dependencies

Runs `busctl` (part of systemd), `omarchy brightness`, `hyprctl`, `omarchy hw`, `upower`, and
(only on hybrid-GPU hardware) `nvidia-smi` via Quickshell's `Process` — all
standard on any Omarchy install except `nvidia-smi`, which is only invoked
when `omarchy hw hybrid gpu` already confirms NVIDIA hardware is present.
Nothing here touches the network. Charge-threshold changes use UPower's
polkit policy or the existing `asusd` system D-Bus policy. `asusd` is optional
and only used when it advertises charge-control support.

## Tests

```
node tests/charge-threshold.test.js
python3 -m unittest discover -s tests -v
bash -n charge-threshold.sh
```

The helper tests mock D-Bus tools; they do not change real charge limits.

## Uninstalling

```
omarchy plugin remove io.github.aryan-techie.battery
```

This removes the plugin and its bar entry. The built-in Power widget (if
you still have it enabled) is unaffected.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).

## Author

**Aryan Techie** ([Aryan Jangra](https://aryan.aroice.in))

- 🌐 Website: [aryan.aroice.in](https://aryan.aroice.in)
- 📧 Email: [aryan@aroice.in](mailto:aryan@aroice.in)
- 🐙 GitHub: [@Aryan-Techie](https://github.com/Aryan-Techie)
- 🏢 Organization: [AROICE](https://aroice.in)

---

<div align="center">

**Made with ❤️ by [AROICE](https://github.com/AROICE-HQ)**

*Clear tools for a clear mind.*

</div>
