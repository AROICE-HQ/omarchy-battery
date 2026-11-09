"""Test the real shell helper with fake D-Bus tools, never changing hardware."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "charge-threshold.sh"
MOCK = Path(__file__).resolve().parent / "fixtures" / "mock_power_tools.py"


class ChargeThresholdTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        for name in ("upower", "busctl"):
            (directory / name).symlink_to(MOCK)
        self.calls = directory / "calls"
        self.limit = directory / "limit"
        self.env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                        CALLS=str(self.calls), LIMIT_FILE=str(self.limit))

    def run_helper(self, *args, scenario="asus", limit=80):
        self.limit.write_text(str(limit))
        return subprocess.run([str(SCRIPT), *args],
                              env=dict(self.env, SCENARIO=scenario),
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
        self.assertEqual(args, [
            "call", "org.freedesktop.UPower",
            "/org/freedesktop/UPower/devices/battery_macsmc_battery",
            "org.freedesktop.UPower.Device", "EnableChargeThreshold", "b", "false",
        ])

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

    def test_asus_discovery_without_upower(self):
        result = self.run_helper("read", scenario="upower-unavailable")
        self.assertEqual(result.stdout, "backend\tasus\nenabled\ttrue\nlimit\t80\n")

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
        self.assertEqual(args, [
            "call", "xyz.ljones.Asusd", "/xyz/ljones", "xyz.ljones.Platform", "OneShotFullCharge",
        ])
        self.assertEqual(self.limit.read_text(), "100")

    def test_restore_saved_not_hardcoded_limit(self):
        result = self.run_helper("set", "asus", "true", "55", limit=100)
        self.assertEqual(result.returncode, 0, result.stderr)
        args, = self.writes()
        self.assertEqual(args, [
            "set-property", "xyz.ljones.Asusd", "/xyz/ljones", "xyz.ljones.Platform",
            "ChargeControlEndThreshold", "y", "55",
        ])
        self.assertEqual(self.limit.read_text(), "55")

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

    def test_asus_success_reply_without_limit_change_is_an_error(self):
        for enabled, limit in (("false", 80), ("true", 100)):
            with self.subTest(enabled=enabled):
                result = self.run_helper("set", "asus", enabled, "80", scenario="no-op", limit=limit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("asusd did not apply the requested charge limit", result.stderr)


if __name__ == "__main__":
    unittest.main()
