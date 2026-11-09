#!/usr/bin/env python3
"""Dry-run harness for a CueSync AR build on a device, a Simulator or CI.

    Scripts/device-dryrun.py <host|url|sim> [options]

Talks only to the app's debug mirror (port 8787), so it behaves the same over
the home LAN, over Tailscale (use the device's tailnet name or 100.x address)
and against the Simulator (`sim` = localhost). Nothing needs copy-pasting
afterwards: everything lands in one run folder, with a machine-readable
report an agent (or CI) can read.

Phases
  1 preflight  state.json reachable, build identity (commit/dirty), /logs works
  2 watch      --seconds N: poll state.json, tail /logs into one file
  3 collect    final logs, state, frame.jpg; --pull-session fetches the latest
               recorded bundle with Scripts/pull-session.sh
  4 evaluate   checks -> report.json + report.md (+ --junit file for CI);
               exit 1 when a REQUIRED check fails

Required by default: reachable, build matches (--expect-sha), logs readable.
Everything else is measured and reported; add --strict to require it all
(use that when someone is standing at a calibrated table).

Run folder: ~/CueSyncRuns/<UTC stamp>-<host>/ (override with --out). Never
inside the repo: it holds frames of a real room and device addresses.
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PORT = 8787
TAILSCALE = shutil.which("tailscale") or "/usr/local/bin/tailscale"


# --------------------------------------------------------------------------
# Mirror access


def resolve_base(target: str) -> str:
    """Turn `sim`, a host, a tailnet name or a URL into http://host:port."""
    if target == "sim":
        return f"http://127.0.0.1:{PORT}"
    if "://" in target:
        return target.rstrip("/")
    host = target
    try:
        socket.gethostbyname(host)
    except OSError:
        # Short tailnet names do not always resolve without MagicDNS on this
        # Mac; ask Tailscale itself.
        try:
            out = subprocess.run([TAILSCALE, "ip", "-4", host], capture_output=True,
                                 text=True, timeout=10)
            ip = out.stdout.strip().splitlines()[0] if out.returncode == 0 else ""
            if ip:
                host = ip
        except (OSError, subprocess.TimeoutExpired, IndexError):
            pass
    return f"http://{host}:{PORT}"


class Mirror:
    def __init__(self, base: str, token: str | None, timeout: float = 8.0):
        self.base, self.token, self.timeout = base, token, timeout

    def url(self, path: str, **params: object) -> str:
        query = {k: v for k, v in params.items() if v is not None}
        if self.token:
            query["t"] = self.token
        return self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")

    def get(self, path: str, timeout: float | None = None, **params: object) -> bytes:
        with urllib.request.urlopen(self.url(path, **params),
                                    timeout=timeout or self.timeout) as r:
            return r.read()

    def state(self) -> dict:
        return json.loads(self.get("/state.json"))

    def logs(self, n: int, since: int, **extra: object) -> str:
        # OSLogStore reads take about 4 s on a device and longer while the app is
        # busy (cold launch), so /logs gets its own, longer timeout.
        return self.get("/logs", timeout=45, n=n, since=since,
                        **extra).decode("utf-8", "replace")

    def command(self, query: str) -> None:
        pairs = urllib.parse.parse_qsl(query, keep_blank_values=True)
        self.get("/cmd", **dict(pairs))


# --------------------------------------------------------------------------
# Checks


class Report:
    def __init__(self) -> None:
        self.checks: list[dict] = []

    def add(self, cid: str, desc: str, ok: bool, detail: str, required: bool) -> None:
        self.checks.append({"id": cid, "description": desc, "pass": bool(ok),
                            "required": required, "detail": detail})

    @property
    def failed_required(self) -> list[dict]:
        return [c for c in self.checks if c["required"] and not c["pass"]]


def git_short_sha() -> str:
    try:
        return subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short=7", "HEAD"],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def pick(samples: list[dict], *path: str) -> list:
    out = []
    for s in samples:
        v: object = s
        for key in path:
            v = v.get(key) if isinstance(v, dict) else None
            if v is None:
                break
        if v is not None:
            out.append(v)
    return out


def evaluate(samples: list[dict], first: dict, logs: str, expect_sha: str,
             strict: bool) -> Report:
    r = Report()
    r.add("reachable", "mirror state.json answers", bool(first), f"{len(samples)} samples", True)

    build = first.get("build") or {}
    commit = str(build.get("commit", "unknown"))
    dirty = build.get("dirty") == "yes"
    if expect_sha:
        r.add("build_matches", f"installed build is {expect_sha}", commit == expect_sha,
              f"device reports {commit} dirty={build.get('dirty')} branch={build.get('branch')}",
              True)
    else:
        r.add("build_identity", "build identity reported", commit != "unknown",
              f"{commit} dirty={build.get('dirty')} branch={build.get('branch')}", False)

    log_lines = [ln for ln in logs.splitlines() if ln.strip()]
    r.add("logs_readable", "/logs returns app log lines", len(log_lines) > 0,
          f"{len(log_lines)} lines", True)
    faults = [ln for ln in log_lines if " fault " in ln]
    errors = [ln for ln in log_lines if " error " in ln]
    r.add("no_faults_in_log", "no fault-level log lines", not faults,
          f"{len(faults)} fault, {len(errors)} error lines", strict)

    r.add("live_tracking_seen", "live tracking became active",
          any(pick(samples, "liveTracking")), "liveTracking true in some sample", strict)
    r.add("calibration_locked_seen", "table calibration locked",
          any(pick(samples, "calibrationLocked")), "calibrationLocked true in some sample",
          strict)
    counts = pick(samples, "ballCount")
    r.add("balls_tracked", "at least one ball tracked", bool(counts) and max(counts) >= 1,
          f"max ballCount {max(counts) if counts else 0}", strict)
    ranked = [s for s in samples if (s.get("ranking") or {}).get("shots")]
    r.add("shot_ranked", "a shot was ranked and offered", bool(ranked),
          f"{len(ranked)}/{len(samples)} samples had ranked shots", strict)
    cue = [s for s in samples if any(b.get("kind") == "cue" for b in s.get("balls", []))]
    r.add("cue_ball_identified", "a cue ball was identified", bool(cue),
          f"{len(cue)}/{len(samples)} samples", strict)

    fps = pick(samples, "health", "cameraFps")
    if fps:
        median = statistics.median(fps)
        r.add("camera_fps", "camera feed >= 30 FPS (checklist row 16)", median >= 30,
              f"median {median:g}, min {min(fps)}", strict)
    lat = pick(samples, "health", "overlayLatencyMs")
    if lat:
        r.add("overlay_latency", "app-side overlay latency <= 100 ms (NOT row 15's number)",
              statistics.median(lat) <= 100,
              f"median {statistics.median(lat):g} ms, worst seen "
              f"{max(pick(samples, 'health', 'worstLatencyMs') or lat)}", strict)
    thermal = set(pick(samples, "health", "thermal"))
    if thermal:
        r.add("thermal_ok", "never serious or critical",
              not (thermal & {"serious", "critical"}), f"seen {sorted(thermal)}", strict)
    last_errors = {e for e in pick(samples, "lastError") if e}
    r.add("no_app_error", "no lastError surfaced in state", not last_errors,
          f"{sorted(last_errors)[:3]}", strict)
    battery = pick(samples, "health", "batteryPercent")
    if len(battery) >= 2:
        r.add("battery_drop", "battery drop reported (checklist row 17: <= 20% per 15 min)",
              True, f"{battery[0]}% -> {battery[-1]}% over the run", False)
    if dirty and expect_sha:
        r.add("build_clean", "build came from a clean tree", False,
              "device build is dirty: its SHA does not pin the code", False)
    return r


def write_reports(out: Path, report: Report, meta: dict) -> None:
    (out / "report.json").write_text(json.dumps({"meta": meta, "checks": report.checks,
                                                 "ok": not report.failed_required}, indent=2))
    rows = ["| check | required | result | detail |", "|---|---|---|---|"]
    for c in report.checks:
        rows.append(f"| {c['id']} | {'yes' if c['required'] else 'no'} | "
                    f"{'PASS' if c['pass'] else 'FAIL'} | {c['detail']} |")
    verdict = "FAILED" if report.failed_required else "OK"
    (out / "report.md").write_text(
        f"# Dry run {verdict}\n\n- target: {meta['target']}\n- build: {meta['build']}\n"
        f"- started: {meta['started']}\n- duration: {meta['seconds']} s\n- samples: "
        f"{meta['samples']}\n\n" + "\n".join(rows) + "\n")


def write_junit(path: Path, report: Report) -> None:
    from xml.sax.saxutils import escape, quoteattr
    cases = []
    for c in report.checks:
        body = ""
        if not c["pass"]:
            tag = "failure" if c["required"] else "skipped"
            body = f"<{tag} message={quoteattr(c['detail'])}/>"
        cases.append(f'<testcase classname="dryrun" name={quoteattr(c["id"])}>{body}</testcase>')
    failures = len(report.failed_required)
    path.write_text(f'<testsuite name="device-dryrun" tests="{len(cases)}" '
                    f'failures="{failures}">{"".join(cases)}</testsuite>')


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("target", help="host, tailnet name, URL, or `sim`")
    ap.add_argument("--out", type=Path, help="run folder (default ~/CueSyncRuns/<stamp>-<host>)")
    ap.add_argument("--seconds", type=int, default=0, help="watch for N seconds (default: none)")
    ap.add_argument("--poll", type=float, default=2.0, help="state poll interval, seconds")
    ap.add_argument("--expect-sha", default="auto",
                    help="short SHA the device must report; `auto` = this checkout's HEAD, "
                         "`none` = do not check")
    ap.add_argument("--send", action="append", default=[], metavar="QUERY",
                    help="mirror command to send first, e.g. action=resetTracking (repeatable)")
    ap.add_argument("--pull-session", action="store_true",
                    help="after the run, pull the latest recorded session bundle")
    ap.add_argument("--strict", action="store_true", help="require every check, not just the core ones")
    ap.add_argument("--junit", type=Path, help="also write a JUnit XML file (for CI)")
    ap.add_argument("--token", default=os.environ.get("CUESYNC_MIRROR_TOKEN"),
                    help="mirror token for builds that require one")
    args = ap.parse_args()

    expect = git_short_sha() if args.expect_sha == "auto" else \
        ("" if args.expect_sha == "none" else args.expect_sha)
    base = resolve_base(args.target)
    mirror = Mirror(base, args.token)
    started = datetime.now(timezone.utc)
    label = urllib.parse.urlparse(base).hostname or "device"
    out = args.out or Path.home() / "CueSyncRuns" / f"{started:%Y%m%dT%H%M%SZ}-{label}"
    out.mkdir(parents=True, exist_ok=True)
    print(f"run folder: {out}\nmirror:     {base}")

    # Phase 1: preflight
    first: dict = {}
    for attempt in range(1, 4):
        try:
            first = mirror.state()
            break
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print(f"preflight attempt {attempt}: {exc}")
            time.sleep(2)
    samples: list[dict] = [first] if first else []
    if first:
        b = first.get("build") or {}
        print(f"build:      {b.get('summary', '?')} branch={b.get('branch')} "
              f"status={first.get('hudStatus')!r}")
    for query in args.send:
        try:
            mirror.command(query)
            print(f"sent:       {query}")
        except (urllib.error.URLError, OSError) as exc:
            print(f"send failed ({query}): {exc}")

    # Phase 2: watch
    t0, next_log = time.time(), 0.0
    log_seen: dict[str, None] = {}
    state_file = (out / "state.jsonl").open("w")
    if first:
        state_file.write(json.dumps({"t": 0, **first}) + "\n")
    while first and time.time() - t0 < args.seconds:
        time.sleep(args.poll)
        try:
            s = mirror.state()
            samples.append(s)
            state_file.write(json.dumps({"t": round(time.time() - t0, 1), **s}) + "\n")
            state_file.flush()
        except (urllib.error.URLError, OSError, ValueError):
            pass
        if time.time() >= next_log:
            next_log = time.time() + 30
            try:
                for ln in mirror.logs(n=2000, since=int(time.time() - t0) + 60).splitlines():
                    log_seen.setdefault(ln)
            except (urllib.error.URLError, OSError, TimeoutError):
                pass
    state_file.close()

    # Phase 3: collect
    logs = ""
    if first:
        try:
            logs = mirror.logs(n=5000, since=3600)
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            logs = ""
            print(f"logs unavailable: {exc}")
        merged = list(log_seen) + [ln for ln in logs.splitlines() if ln not in log_seen]
        (out / "device.log").write_text("\n".join(merged) + ("\n" if merged else ""))
        logs = "\n".join(merged)
        (out / "state-final.json").write_text(json.dumps(samples[-1], indent=2, sort_keys=True))
        try:
            (out / "frame.jpg").write_bytes(mirror.get("/frame.jpg"))
        except (urllib.error.URLError, OSError):
            pass
        if args.pull_session:
            host = urllib.parse.urlparse(base).hostname or ""
            rc = subprocess.run([str(REPO / "Scripts" / "pull-session.sh"), host, "latest",
                                 str(out / "Sessions")]).returncode
            print(f"pull-session exit {rc}")

    # Phase 4: evaluate
    report = evaluate(samples, first, logs, expect, args.strict)
    b = (first.get("build") or {})
    meta = {"target": base, "build": b.get("summary", "unreachable"),
            "started": started.isoformat(timespec="seconds"),
            "seconds": round(time.time() - t0), "samples": len(samples)}
    write_reports(out, report, meta)
    if args.junit:
        write_junit(args.junit, report)
    for c in report.checks:
        print(f"  {'PASS' if c['pass'] else 'FAIL'}{'*' if c['required'] else ' '} "
              f"{c['id']}: {c['detail']}")
    latest = Path.home() / "CueSyncRuns" / "latest"
    try:
        latest.parent.mkdir(parents=True, exist_ok=True)
        latest.unlink(missing_ok=True)
        latest.symlink_to(out.resolve())
    except OSError:
        pass
    print(f"report: {out / 'report.md'}   (also ~/CueSyncRuns/latest)")
    print("RESULT: " + ("FAILED (" + ", ".join(c['id'] for c in report.failed_required) + ")"
                        if report.failed_required else "OK"))
    return 1 if report.failed_required else 0


if __name__ == "__main__":
    sys.exit(main())
