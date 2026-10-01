# Changelog

All notable user-facing changes to this plugin. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Fixed

- Require UPower's charge-threshold switch to be enabled before labeling a
  partly charged battery as "Holding". This avoids mistaking a battery that
  reports `fully-charged` below 99% for an active charge limit.
- Show "Battery state / Fully charged" and the zero charge rate instead of the
  contradictory "Time to full / Charging" rows when the battery is full.
- Round the panel percentage from the same live UPower value as the bar, so a
  value such as 92.99% no longer appears as 92% in one place and 93% in another.
- Constrain stat labels and values to their row, preventing long state text
  from being clipped at the panel's right edge.

### Added

- Add a Power Impact section that groups recent process CPU activity by
  application and shows the three busiest applications while the panel is
  open, with an explicit estimate disclaimer.
- Show the battery's real temperature in the stats when Linux exposes a
  battery temperature sensor.

## v0.1.0 — Initial release

### Added

- Everything Omarchy's built-in Power widget already does, unchanged:
  battery percentage/bar, size/cycles/time/rate stats, charge-threshold
  detection, power-profile picker.
- **Charge-threshold toggle** — enable/disable firmware-backed charge
  protection via UPower's own `EnableChargeThreshold` method. Only shown
  when the battery reports a configured threshold.
- **Quick Dim** — one-click 40% brightness with exact restore, reading
  current brightness first so it never guesses.
- **Travel Mode** — saves power profile, brightness, and monitor refresh
  rate as one bundle; applies a travel preset; restores all three on
  toggle-off. Session-only.
- **GPU status** — discrete-GPU power draw and utilization, shown only on
  hybrid-GPU hardware.
- **Power draw history** — a 10-minute in-memory sparkline plus a live
  watts readout, built from data the widget already samples. No database.
- Independent plugin id (`io.github.aryan-techie.battery`) — installs
  alongside the built-in widget rather than replacing it, so both can run
  side by side while you decide which one to keep on the bar.
