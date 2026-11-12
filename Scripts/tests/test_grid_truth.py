#!/usr/bin/env python3
"""Tests for Scripts/grid-truth.py and its use in device-dryrun.py / calibrate-pockets.py.

    python3 -m unittest discover -s Scripts/tests

Synthetic data only: the fixtures are built here from the grid definition.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gt = load("grid_truth", "grid-truth.py")
dryrun = load("device_dryrun", "device-dryrun.py")
calibrate = load("calibrate_pockets", "calibrate-pockets.py")

L = 2.34
S = L / 8


def perfect_balls(length: float = L, dx: float = 0.0, dy: float = 0.0,
                  stretch_x: float = 1.0) -> list[dict]:
    """15 object balls on the grid, optionally shifted or compressed along x."""
    s = length / 8
    balls = [{"kind": "solid(1)", "colour": "c", "x": k * s * stretch_x + dx, "y": j * s + dy}
             for k in gt.OCCUPIED_ROWS for j in gt.OCCUPIED_COLS]
    return balls


class ScoreTests(unittest.TestCase):
    def test_perfect_grid_has_zero_error(self):
        r = gt.score(perfect_balls(), L)
        self.assertEqual(r["n"], 15)
        self.assertAlmostEqual(r["rms_cm"], 0.0, places=9)
        self.assertAlmostEqual(r["max_cm"], 0.0, places=9)
        self.assertEqual(r["claimed_twice"], 0)
        self.assertEqual(r["unclaimed"], [])
        self.assertAlmostEqual(r["fit_x"]["ratio"], 1.0, places=9)
        self.assertAlmostEqual(r["fit_y"]["ratio"], 1.0, places=9)

    def test_x_shift_of_5cm_shows_in_mean_dx(self):
        r = gt.score(perfect_balls(dx=0.05), L)
        self.assertAlmostEqual(r["mean_dx_cm"], 5.0, places=6)
        self.assertAlmostEqual(r["mean_dy_cm"], 0.0, places=6)
        self.assertAlmostEqual(r["rms_cm"], 5.0, places=6)
        self.assertEqual(r["claimed_twice"], 0)
        # A pure shift moves the offset, not the spacing.
        self.assertAlmostEqual(r["fit_x"]["offset_m"], 0.05, places=9)
        self.assertAlmostEqual(r["fit_x"]["ratio"], 1.0, places=9)

    def test_missing_ball_is_reported_unclaimed(self):
        balls = perfect_balls()
        gone = balls.pop(0)  # k=3, j=1
        r = gt.score(balls, L)
        self.assertEqual(r["n"], 14)
        self.assertEqual(r["unclaimed"], [{"k": 3, "j": 1}])
        self.assertEqual(r["claimed_twice"], 0)
        self.assertAlmostEqual(gone["x"], 3 * S)
        self.assertAlmostEqual(r["rms_cm"], 0.0, places=9)

    def test_cue_ball_is_ignored(self):
        balls = perfect_balls() + [{"kind": "cue", "colour": "white", "x": 0.3, "y": 0.1}]
        r = gt.score(balls, L)
        self.assertEqual(r["n"], 15)
        self.assertAlmostEqual(r["rms_cm"], 0.0, places=9)

    def test_ball_claimed_twice(self):
        balls = perfect_balls()
        balls.pop(0)  # k=3, j=1 leaves
        balls.append({"kind": "solid(9)", "colour": "c", "x": 0.0 + 0.02, "y": 0.0})  # near k=0, j=0
        r = gt.score(balls, L)
        self.assertEqual(r["n"], 15)
        self.assertEqual(r["claimed_twice"], 1)
        self.assertEqual(r["unclaimed"], [{"k": 3, "j": 1}])

    def test_empty_rows_are_not_grid_points(self):
        # A ball at row k=1 (empty) snaps to the nearest OCCUPIED point, with the
        # full distance counted as error.
        r = gt.score([{"kind": "solid(1)", "colour": "c", "x": 0.9 * S, "y": 0.0}], L)
        self.assertEqual(r["balls"][0]["k"], 0)  # not k=1: that row is empty
        self.assertAlmostEqual(r["balls"][0]["err_cm"], 0.9 * S * 100, places=6)

    def test_spacing_fit_detects_4_percent_compression(self):
        r = gt.score(perfect_balls(stretch_x=0.96), L)
        self.assertAlmostEqual(r["fit_x"]["ratio"], 0.96, places=6)
        self.assertAlmostEqual(r["fit_x"]["length_m"], L * 0.96, places=6)
        self.assertAlmostEqual(r["fit_y"]["ratio"], 1.0, places=6)
        self.assertGreater(r["rms_cm"], 1.0)  # and the grid error alone is visible too

    def test_alternate_length(self):
        r = gt.score(perfect_balls(length=2.235), 2.235)
        self.assertAlmostEqual(r["rms_cm"], 0.0, places=9)
        self.assertAlmostEqual(r["spacing_m"], 2.235 / 8)

    def test_no_balls(self):
        r = gt.score([{"kind": "cue", "x": 0, "y": 0}], L)
        self.assertEqual(r["n"], 0)
        self.assertIsNone(r["rms_cm"])
        self.assertIsNone(r["fit_x"])
        self.assertIn("n=0", gt.format_report(r))


class ParseLengthTests(unittest.TestCase):
    def test_named_and_numeric(self):
        self.assertEqual(gt.parse_length("eightFoot"), 2.34)
        self.assertEqual(gt.parse_length("sevenFoot"), 1.98)
        self.assertEqual(gt.parse_length("2.235"), 2.235)
        self.assertEqual(gt.parse_length("2.235,1.118"), 2.235)

    def test_rejects_garbage(self):
        for bad in ("tenFoot", "", "0.1", "9"):
            with self.assertRaises(argparse.ArgumentTypeError):
                gt.parse_length(bad)


class CliTests(unittest.TestCase):
    def run_cli(self, args: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = gt.main(args)
            except SystemExit as exc:  # argparse errors
                code = int(exc.code or 0)
        return code, out.getvalue(), err.getvalue()

    def write_state(self, balls: list[dict]) -> str:
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump({"balls": balls}, f)
        self.addCleanup(os.unlink, path)
        return path

    def test_text_report(self):
        code, out, _ = self.run_cli([self.write_state(perfect_balls(dx=0.05))])
        self.assertEqual(code, 0)
        self.assertIn("n=15 rms 5.0 cm", out)
        self.assertIn("mean dx +5.0 cm", out)
        self.assertIn("grid points claimed twice: 0", out)
        self.assertIn("free fit x", out)

    def test_json_output_and_size_flag(self):
        path = self.write_state(perfect_balls(length=2.235))
        code, out, _ = self.run_cli([path, "--size", "2.235", "--json"])
        self.assertEqual(code, 0)
        self.assertAlmostEqual(json.loads(out)["rms_cm"], 0.0, places=6)

    def test_max_rms_gate(self):
        path = self.write_state(perfect_balls(dx=0.05))
        self.assertEqual(self.run_cli([path, "--max-rms-cm", "4"])[0], 1)
        self.assertEqual(self.run_cli([path, "--max-rms-cm", "6"])[0], 0)

    def test_unreadable_input_exits_2(self):
        code, _, err = self.run_cli(["/nonexistent/state.json", "--retries", "1"])
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err)

    def test_state_without_balls_exits_2(self):
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump({"nope": 1}, f)
        self.addCleanup(os.unlink, path)
        self.assertEqual(self.run_cli([path])[0], 2)


class DryrunGridCheckTests(unittest.TestCase):
    def test_advisory_check_recorded_with_metrics(self):
        r = dryrun.Report()
        dryrun.add_grid_check(r, [{"balls": perfect_balls(dx=0.05)}], L)
        (check,) = r.checks
        self.assertEqual(check["id"], "grid_error")
        self.assertFalse(check["required"])
        self.assertTrue(check["pass"])
        self.assertAlmostEqual(check["metrics"]["rms_cm"], 5.0, places=1)
        self.assertEqual(r.failed_required, [])

    def test_missing_balls_never_fails_the_run(self):
        r = dryrun.Report()
        dryrun.add_grid_check(r, [{"balls": []}], L)
        self.assertFalse(r.checks[0]["pass"])
        self.assertEqual(r.failed_required, [])

    def test_evaluate_without_grid_adds_nothing(self):
        r = dryrun.evaluate([{}], {"build": {}}, "", "", False)
        self.assertNotIn("grid_error", [c["id"] for c in r.checks])
        r = dryrun.evaluate([{"balls": perfect_balls()}], {"build": {}}, "", "", False, L)
        self.assertIn("grid_error", [c["id"] for c in r.checks])

    def test_table_length_from_state(self):
        self.assertEqual(dryrun.table_length_from_state({"tableSize": "2.34 x 1.17 m"}), 2.34)
        self.assertIsNone(dryrun.table_length_from_state({}))

    def test_junit_and_reports_carry_grid_numbers(self):
        r = dryrun.Report()
        dryrun.add_grid_check(r, [{"balls": perfect_balls()}], L)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            dryrun.write_junit(out / "j.xml", r)
            dryrun.write_reports(out, r, {"target": "t", "build": "b", "started": "s",
                                          "seconds": 0, "samples": 1})
            self.assertIn('name="grid_error"', (out / "j.xml").read_text())
            self.assertIn("grid_error", (out / "report.md").read_text())
            self.assertIn("rms_cm", (out / "report.json").read_text())


class CalibrateArgsTests(unittest.TestCase):
    def test_parse_size(self):
        self.assertEqual(calibrate.parse_size("nineFoot"), "nineFoot")
        self.assertEqual(calibrate.parse_size("2.235,1.118"), "2.235,1.118")
        for bad in ("eightfoot", "2.235", "1.1,2.2", "a,b"):
            with self.assertRaises(argparse.ArgumentTypeError):
                calibrate.parse_size(bad)

    def test_warns_when_still_on_previous_lock(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            calibrate.warn_if_unlocked({"locked": False})
            calibrate.warn_if_unlocked({"locked": True})
        self.assertEqual(err.getvalue().count("STILL on its previous lock"), 1)

    def test_reset_sequence(self):
        sent: list[dict] = []
        original_get, original_sleep = calibrate.get, calibrate.time.sleep
        calibrate.get = lambda base, path, **q: sent.append(q) or b""
        calibrate.time.sleep = lambda s: None
        try:
            calibrate.reset_hold("http://x", 2.5)
        finally:
            calibrate.get, calibrate.time.sleep = original_get, original_sleep
        self.assertEqual(sent, [{"action": "parkedHold", "v": "0"},
                                {"action": "parkedHold", "v": "1"},
                                {"action": "beginCalibration"}])

    def test_final_state_read_retries(self):
        calls = {"n": 0}
        original_get, original_sleep = calibrate.get, calibrate.time.sleep

        def flaky(base, path, **q):
            calls["n"] += 1
            if calls["n"] < 3:
                raise ConnectionRefusedError("refused")
            return b"{}"

        calibrate.get, calibrate.time.sleep = flaky, lambda s: None
        try:
            self.assertEqual(calibrate.get_retry("http://x", "/state.json", 3), b"{}")
            calls["n"] = -10
            with self.assertRaises(ConnectionRefusedError):
                calibrate.get_retry("http://x", "/state.json", 2)
        finally:
            calibrate.get, calibrate.time.sleep = original_get, original_sleep


if __name__ == "__main__":
    unittest.main()
