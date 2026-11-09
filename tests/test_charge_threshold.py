"""Test the real shell helper with fake D-Bus tools, never changing hardware."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "charge-threshold.sh"
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
if Path(sys.argv[0]).name == "upower":
    print("/org/freedesktop/UPower/devices/battery_mouse")
    print("/org/freedesktop/UPower/devices/battery_macsmc_battery")
    sys.exit(0)

scenario = os.environ["SCENARIO"]
method = args[args.index("--method") + 1]
if method.endswith(".Set") or method.endswith(".EnableChargeThreshold") or method.endswith(".OneShotFullCharge"):
    with open(os.environ["CALLS"], "a") as log:
        log.write(json.dumps(args) + "\n")
    if scenario == "denied":
        print("Access denied", file=sys.stderr)
        sys.exit(1)
    print("()")
elif args[-1] == "PowerSupply":
    device = args[args.index("--object-path") + 1]
    print("(<false>,)" if device.endswith("_mouse") else "(<true>,)")
elif args[-1] == "ChargeThresholdSupported":
    if scenario == "old-upower":
        sys.exit(1)
    print("(<true>,)" if scenario.startswith("upower") else "(<false>,)")
elif args[-1] == "ChargeThresholdEnabled":
    if scenario == "upower-read-error":
        sys.exit(1)
    print("(<false>,)" if scenario == "upower-disabled" else "(<true>,)")
elif method.endswith(".SupportedProperties"):
    if scenario == "no-daemon":
        sys.exit(1)
    print("(['ThrottlePolicy'],)" if scenario == "unsupported" else "(['ChargeControlEndThreshold'],)")
elif args[-1] == "ChargeControlEndThreshold":
    if scenario == "malformed":
        print("invalid")
    else:
        print("(<byte 0x%02x>,)" % int(os.environ.get("LIMIT", "80")))
else:
    sys.exit(1)
'''


class ChargeThresholdTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        for name in ("upower", "gdbus"):
            tool = directory / name
            tool.write_text(MOCK)
            tool.chmod(0o755)
        self.calls = directory / "calls"
        self.env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                        SCENARIO="asus", CALLS=str(self.calls))

    def run_helper(self, *args, scenario="asus", limit=80):
        return subprocess.run(["bash", str(SCRIPT), *args],
                              env=dict(self.env, SCENARIO=scenario, LIMIT=str(limit)),
                              capture_output=True, text=True, timeout=10)

    def writes(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_upower_preferred_and_peripheral_ignored(self):
        result = self.run_helper("read", scenario="upower")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "backend\tupower\nenabled\ttrue\nlimit\t0\n")
        result = self.run_helper("set", "upower", "false", "0", scenario="upower")
        self.assertEqual(result.returncode, 0, result.stderr)
        args, = self.writes()
        self.assertEqual(args[-1], "false")
        self.assertIn("org.freedesktop.UPower.Device.EnableChargeThreshold", args)
        self.assertIn("/org/freedesktop/UPower/devices/battery_macsmc_battery", args)

    def test_disabled_upower_still_available(self):
        result = self.run_helper("read", scenario="upower-disabled")
        self.assertEqual(result.stdout, "backend\tupower\nenabled\tfalse\nlimit\t0\n")

    def test_asus_limit_and_disabled_state(self):
        for limit in (20, 55, 80, 99, 100):
            result = self.run_helper("read", limit=limit)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"backend\tasus\nenabled\t{str(limit < 100).lower()}\nlimit\t{limit}\n")
        self.assertEqual(self.writes(), [])

    def test_old_upower_can_fall_back(self):
        result = self.run_helper("read", scenario="old-upower")
        self.assertIn("backend\tasus\n", result.stdout)

    def test_unsupported_and_bad_reads_do_not_claim_support(self):
        for scenario in ("unsupported", "no-daemon", "malformed", "upower-read-error"):
            self.assertEqual(self.run_helper("read", scenario=scenario).stdout, "backend\tnone\n")
        for limit in (0, 19, 101, 255):
            self.assertEqual(self.run_helper("read", limit=limit).stdout, "backend\tnone\n")
        self.assertEqual(self.writes(), [])

    def test_asus_disable_uses_no_argument_oneshot(self):
        result = self.run_helper("set", "asus", "false", "55", limit=55)
        self.assertEqual(result.returncode, 0, result.stderr)
        args, = self.writes()
        self.assertEqual(args[-1], "xyz.ljones.Platform.OneShotFullCharge")

    def test_restore_saved_not_hardcoded_limit(self):
        result = self.run_helper("set", "asus", "true", "55", limit=100)
        self.assertEqual(result.returncode, 0, result.stderr)
        args, = self.writes()
        self.assertEqual(args[-3:], ["xyz.ljones.Platform", "ChargeControlEndThreshold", "<byte 55>"])

    def test_reject_bad_restore_values_and_arguments(self):
        for value in ("0", "19", "100", "101", "80.5", "080", "80;echo unsafe", "<img>"):
            self.assertNotEqual(self.run_helper("set", "asus", "true", value).returncode, 0)
        for args in (("set",), ("set", "asus", "maybe", "80"), ("bogus",)):
            self.assertNotEqual(self.run_helper(*args).returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_backend_change_and_disappearance_never_write(self):
        self.assertNotEqual(self.run_helper("set", "asus", "false", "80", scenario="upower").returncode, 0)
        self.assertNotEqual(self.run_helper("set", "upower", "true", "80").returncode, 0)
        self.assertNotEqual(self.run_helper("set", "asus", "false", "80", scenario="no-daemon").returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_external_limit_change_needs_refresh(self):
        self.assertNotEqual(self.run_helper("set", "asus", "false", "80", limit=55).returncode, 0)
        self.assertNotEqual(self.run_helper("set", "asus", "true", "80", limit=55).returncode, 0)
        self.assertNotEqual(self.run_helper("set", "asus", "false", "80", limit=100).returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_action_errors_propagate(self):
        result = self.run_helper("set", "asus", "false", "80", scenario="denied")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Access denied", result.stderr)


if __name__ == "__main__":
    unittest.main()
