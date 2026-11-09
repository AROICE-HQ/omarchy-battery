#!/usr/bin/env python3
"""Fake upower and busctl executables used by the charge-threshold tests."""
import json
import os
from pathlib import Path
import sys

UPOWER = "org.freedesktop.UPower"
UPOWER_DEVICE = "org.freedesktop.UPower.Device"
ASUSD = "xyz.ljones.Asusd"
ASUS_PATH = "/xyz/ljones"
ASUS_PLATFORM = "xyz.ljones.Platform"
BATTERY = "/org/freedesktop/UPower/devices/battery_macsmc_battery"
MOUSE = "/org/freedesktop/UPower/devices/battery_mouse"
THRESHOLD = "ChargeControlEndThreshold"


def main():
    scenario = os.environ["SCENARIO"]
    if Path(sys.argv[0]).name == "upower":
        if scenario == "upower-unavailable":
            return 1
        print(MOUSE, BATTERY, sep="\n")
        return 0

    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    operation, service, path, interface, *payload = args
    limit = Path(os.environ["LIMIT_FILE"])

    if (service, path, interface) == (ASUSD, ASUS_PATH, ASUS_PLATFORM):
        if scenario == "no-daemon":
            return 1
        if [operation, *payload] == ["call", "SupportedProperties"]:
            print('as 1 "ThrottlePolicy"' if scenario == "unsupported" else
                  f'as 2 "ThrottlePolicy" "{THRESHOLD}"')
            return 0
        if [operation, *payload] == ["get-property", THRESHOLD]:
            print("invalid" if scenario == "malformed" else f"y {limit.read_text()}")
            return 0
        if [operation, *payload] == ["call", "OneShotFullCharge"]:
            return write(args, scenario, limit, "100")
        if operation == "set-property" and payload[:2] == [THRESHOLD, "y"]:
            return write(args, scenario, limit, payload[2])

    if service == UPOWER and interface == UPOWER_DEVICE:
        if [operation, *payload] == ["get-property", "PowerSupply"]:
            print("b true" if path == BATTERY else "b false")
            return 0
        if path != BATTERY:
            return 1
        if [operation, *payload] == ["get-property", "ChargeThresholdSupported"]:
            if scenario == "old-upower":
                return 1
            print("b true" if scenario.startswith("upower") else "b false")
            return 0
        if [operation, *payload] == ["get-property", "ChargeThresholdEnabled"]:
            if scenario == "upower-read-error":
                return 1
            print("b false" if scenario == "upower-disabled" else "b true")
            return 0
        if operation == "call" and payload[:2] == ["EnableChargeThreshold", "b"]:
            return write(args, scenario, limit, limit.read_text())

    return 1


def write(args, scenario, limit, target):
    with Path(os.environ["CALLS"]).open("a") as log:
        log.write(json.dumps(args) + "\n")
    if scenario == "denied":
        print("Access denied", file=sys.stderr)
        return 1
    if scenario != "no-op":
        limit.write_text(target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
