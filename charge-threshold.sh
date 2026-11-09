#!/usr/bin/env bash
# Prefer UPower's generic API; use asusd only when it advertises charge control.
# Never write sysfs or guess a protection percentage.
set -euo pipefail
export LC_ALL=C

upower_property() {
  gdbus call --system --timeout 5 --dest org.freedesktop.UPower \
    --object-path "$battery" --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.UPower.Device "$1"
}

asus_call() {
  gdbus call --system --timeout 5 --dest xyz.ljones.Asusd \
    --object-path /xyz/ljones --method "$@"
}

find_battery() {
  local device
  while IFS= read -r device; do
    [[ "$device" == /org/freedesktop/UPower/devices/battery_* ]] || continue
    if [[ "$(gdbus call --system --timeout 5 --dest org.freedesktop.UPower \
      --object-path "$device" --method org.freedesktop.DBus.Properties.Get \
      org.freedesktop.UPower.Device PowerSupply 2>/dev/null)" == '(<true>,)' ]]; then
      battery="$device"
      return 0
    fi
  done < <(upower -e)
  return 1
}

detect_backend() {
  local supported value
  find_battery || return 1
  if [[ "$(upower_property ChargeThresholdSupported 2>/dev/null)" == '(<true>,)' ]]; then
    backend=upower
    value="$(upower_property ChargeThresholdEnabled)" || return 1
    case "$value" in
      '(<true>,)') enabled=true ;;
      '(<false>,)') enabled=false ;;
      *) return 1 ;;
    esac
    limit=0
    return 0
  fi

  supported="$(asus_call xyz.ljones.Platform.SupportedProperties 2>/dev/null)" || return 1
  [[ "$supported" == *"'ChargeControlEndThreshold'"* ]] || return 1
  value="$(asus_call org.freedesktop.DBus.Properties.Get \
    xyz.ljones.Platform ChargeControlEndThreshold)" || return 1
  [[ "$value" =~ ^\(\<byte\ 0x([[:xdigit:]]{2})\>\,\)$ ]] || return 1
  limit=$((16#${BASH_REMATCH[1]}))
  (( limit >= 20 && limit <= 100 )) || return 1
  backend=asus
  enabled=false
  (( limit == 100 )) || enabled=true
}

case "${1:-read}" in
  read)
    if detect_backend; then
      printf 'backend\t%s\nenabled\t%s\nlimit\t%s\n' "$backend" "$enabled" "$limit"
    else
      printf 'backend\tnone\n'
    fi
    ;;
  set)
    # Re-detect before writing: never send an ASUS action to a UPower device
    # (or vice versa) after the backend disappears or changes.
    [[ $# == 4 && "$3" =~ ^(true|false)$ ]] || exit 1
    detect_backend || exit 1
    [[ "$backend" == "$2" ]] || exit 1
    if [[ "$backend" == upower ]]; then
      gdbus call --system --timeout 5 --dest org.freedesktop.UPower \
        --object-path "$battery" --method org.freedesktop.UPower.Device.EnableChargeThreshold "$3"
    else
      [[ "$4" =~ ^[0-9]{2}$ ]] && (( 10#$4 >= 20 && 10#$4 < 100 )) || exit 1
      if [[ "$3" == false ]]; then
        # An external limit change needs a UI refresh before saving/restoring
        # it. Do not override another client's newer choice with stale state.
        (( limit == 10#$4 )) || exit 1
        # No percentage argument: preserve asusd's normal limit for unplug.
        asus_call xyz.ljones.Platform.OneShotFullCharge
      else
        (( limit == 100 )) || exit 1
        asus_call org.freedesktop.DBus.Properties.Set xyz.ljones.Platform \
          ChargeControlEndThreshold "<byte $4>"
      fi
    fi
    ;;
  *) exit 1 ;;
esac
