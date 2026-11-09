#!/usr/bin/env bash
set -u
export LC_ALL=C

readonly upower_service=org.freedesktop.UPower
readonly upower_device=org.freedesktop.UPower.Device
readonly asus_service=xyz.ljones.Asusd
readonly asus_path=/xyz/ljones
readonly asus_platform=xyz.ljones.Platform
readonly asus_threshold=ChargeControlEndThreshold

system_bus() {
  busctl --system --timeout=5s "$@"
}

upower_property() {
  system_bus get-property "$upower_service" "$1" "$upower_device" "$2"
}

asus_bus() {
  local operation=$1
  shift
  system_bus --auto-start=no "$operation" "$asus_service" "$asus_path" "$asus_platform" "$@"
}

find_system_battery() {
  local device
  while IFS= read -r device; do
    [[ $device == /org/freedesktop/UPower/devices/battery_* ]] || continue
    if [[ $(upower_property "$device" PowerSupply 2>/dev/null) == 'b true' ]]; then
      printf '%s\n' "$device"
      return 0
    fi
  done < <(upower -e 2>/dev/null)
  return 1
}

read_asus_limit() {
  local value
  value=$(asus_bus get-property "$asus_threshold") || return 1
  [[ $value =~ ^y\ (100|[2-9][0-9])$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

detect_backend() {
  local value
  if battery=$(find_system_battery) &&
     [[ $(upower_property "$battery" ChargeThresholdSupported 2>/dev/null) == 'b true' ]]; then
    value=$(upower_property "$battery" ChargeThresholdEnabled) || return 1
    case "$value" in
      'b true') enabled=true ;;
      'b false') enabled=false ;;
      *) return 1 ;;
    esac
    backend=upower
    limit=0
    return 0
  fi

  value=$(asus_bus call SupportedProperties 2>/dev/null) || return 1
  [[ $value == as\ *\"$asus_threshold\"* ]] || return 1
  limit=$(read_asus_limit) || return 1
  backend=asus
  if [[ $limit != 100 ]]; then
    enabled=true
  else
    enabled=false
  fi
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
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
    [[ $# == 4 && $2 =~ ^(upower|asus)$ && $3 =~ ^(true|false)$ ]] ||
      fail "Usage: charge-threshold.sh set {upower|asus} {true|false} saved-limit"
    detect_backend || fail "Charge control is unavailable"
    [[ $backend == "$2" ]] || fail "The charge control backend changed"

    if [[ $backend == upower ]]; then
      system_bus --allow-interactive-authorization=yes --quiet call \
        "$upower_service" "$battery" "$upower_device" EnableChargeThreshold b "$3"
      exit $?
    fi

    saved_limit=$4
    [[ $saved_limit =~ ^[2-9][0-9]$ ]] || fail "Invalid saved ASUS charge limit"
    if [[ $3 == false ]]; then
      [[ $limit == "$saved_limit" ]] || fail "The ASUS charge limit changed"
      asus_bus call OneShotFullCharge >/dev/null || exit 1
      expected_limit=100
    else
      [[ $limit == 100 ]] || fail "The ASUS charge limit changed"
      asus_bus set-property "$asus_threshold" y "$saved_limit" || exit 1
      expected_limit=$saved_limit
    fi

    # asusd can acknowledge a one-shot request without changing the live limit.
    [[ $(read_asus_limit) == "$expected_limit" ]] ||
      fail "asusd did not apply the requested charge limit"
    ;;
  *) fail "Usage: charge-threshold.sh {read|set}" ;;
esac
