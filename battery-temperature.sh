#!/usr/bin/env bash

set -u

# The Linux power-supply ABI reports battery temperature in tenths of a
# degree Celsius. Not every battery exposes the attribute; no output lets the
# panel hide the row cleanly on unsupported hardware.
for battery in /sys/class/power_supply/BAT*; do
  [[ -r $battery/temp ]] || continue
  IFS= read -r raw <"$battery/temp" || continue
  [[ $raw =~ ^-?[0-9]+$ ]] || continue
  awk -v raw="$raw" 'BEGIN { printf "%.1f\n", raw / 10 }'
  exit 0
done

