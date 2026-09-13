#!/usr/bin/env python3
"""Interleave host and plugin-free startup/first-input baselines."""

from __future__ import annotations

import argparse
import json
import os
import platform
import secrets
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import msgpack
import pynvim

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tests.e2e.driver import PLUGIN_ROOT, ProbeRun, host_config_root, new_output


def percentile(values: list[float], percent: float) -> float:
    ordered = sorted(values)
    rank = max(1, int((len(ordered) * percent + 99) // 100))
    return ordered[min(rank - 1, len(ordered) - 1)]


def xdg_environment(root: Path, isolated_config: bool) -> dict[str, str]:
    env = os.environ.copy()
    for name in ("data", "state", "cache"):
        (root / name).mkdir()
        env[f"XDG_{name.upper()}_HOME"] = str(root / name)
    if isolated_config:
        (root / "config").mkdir()
        env["XDG_CONFIG_HOME"] = str(root / "config")
    elif host_config_root() is not None:
        env["XDG_CONFIG_HOME"] = str(host_config_root().parent)
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def startup_sample(nvim: str, host: bool, output: Path, sample_id: int) -> dict[str, Any]:
    config_root = host_config_root()
    if host and config_root is None:
        raise RuntimeError("host configuration was not found; startup baseline cannot be measured")
    sample_root = output / f"startup-{sample_id:03d}-{'host' if host else 'plugin-free'}"
    sample_root.mkdir()
    log = sample_root / "startup.log"
    with tempfile.TemporaryDirectory(prefix="wb-bench-xdg-") as temporary:
        env = xdg_environment(Path(temporary), isolated_config=not host)
        command = [nvim, "-n", "-i", "NONE", "--headless", "--startuptime", str(log)]
        if host:
            command.extend(["-u", str(config_root / "init.lua")])
        else:
            command.extend(["--clean"])
        command.extend(["-c", "qa!"])
        started = time.perf_counter()
        try:
            result = subprocess.run(command, env=env, cwd=PLUGIN_ROOT, text=True, capture_output=True, check=False, timeout=15)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"startup process exceeded 15 seconds: {' '.join(command)}") from error
        wall_ms = (time.perf_counter() - started) * 1000
    if result.returncode != 0:
        raise RuntimeError(f"startup command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    marker = None
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            if "--- NVIM STARTED ---" in line:
                marker = float(line.split()[0])
                break
    if marker is None:
        raise RuntimeError(f"no --- NVIM STARTED --- marker in {log}")
    return {"startup_marker_ms": marker, "process_wall_ms": round(wall_ms, 3), "log": str(log)}


def summarize(samples: list[dict[str, Any]], key: str) -> dict[str, float]:
    values = [float(sample[key]) for sample in samples]
    return {
        "p50_ms": round(statistics.median(values), 3),
        "p95_ms": round(percentile(values, 95), 3),
        "min_ms": round(min(values), 3),
        "max_ms": round(max(values), 3),
    }


def expensive_profile_rows(path: Path, threshold_ms: float = 5.0) -> list[str]:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split()
        if len(fields) < 3 or ":" not in line:
            continue
        try:
            elapsed = float(fields[1])
        except ValueError:
            continue
        if elapsed > threshold_ms:
            rows.append(line.strip())
    return rows


def fixture_inventory(root: Path) -> list[dict[str, Any]]:
    latest: dict[str, tuple[str, dict[str, Any]]] = {}
    if not root.exists():
        return []
    for manifest in root.glob("*/fixture.json"):
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        tier = data.get("tier")
        generated = data.get("generated_at_utc", "")
        if tier and (tier not in latest or generated > latest[tier][0]):
            latest[tier] = (generated, {**data, "manifest": str(manifest)})
    return [latest[tier][1] for tier in sorted(latest)]


def revision(path: Path) -> str:
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], text=True, capture_output=True, check=True)
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--nvim", default=os.environ.get("NVIM", "nvim"))
    parser.add_argument("--output-root", type=Path, default=PLUGIN_ROOT / ".bench-output" / "startup")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    config_root = host_config_root()
    if config_root is None:
        parser.error("host config checkout was not found")

    output = new_output(args.output_root, "baseline")
    output.mkdir(parents=True, exist_ok=False)
    samples: dict[str, list[dict[str, Any]]] = {"host": [], "plugin_free": []}

    for index in range(args.runs):
        order = ("host", "plugin_free") if index % 2 == 0 else ("plugin_free", "host")
        for name in order:
            host = name == "host"
            startup = startup_sample(args.nvim, host, output, index * 2 + (0 if name == order[0] else 1))
            run_dir = new_output(output, f"ui-{index:02d}-{name}")
            interactive = ProbeRun(args.nvim, 80, 24, "probe", run_dir, host=host).run()
            samples[name].append(
                {
                    **startup,
                    "ui_first_frame_ms": interactive["startup_to_first_flush_ms"],
                    "first_input_state_ms": interactive["first_input_state_ms"],
                    "startup_log_marker_in_ui_run_ms": interactive["startup_marker_ms"],
                    "ui_artifacts": str(run_dir),
                }
            )

    nvim_version = subprocess.run([args.nvim, "--version"], text=True, capture_output=True, check=True).stdout.splitlines()[0]
    first_host_log = output / "startup-000-host" / "startup.log"
    first_minimal_log = output / "startup-001-plugin-free" / "startup.log"
    machine_model = ""
    if platform.system() == "Darwin":
        model_result = subprocess.run(["sysctl", "-n", "hw.model"], text=True, capture_output=True, check=False)
        machine_model = model_result.stdout.strip()
    report = {
        "environment": {
            "os": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "machine_model": machine_model,
            "cpu_count": os.cpu_count(),
            "nvim": nvim_version,
            "minimum_nvim": "0.11.7",
            "pynvim": pynvim.__version__,
            "msgpack": msgpack.__version__,
            "workbench_git_head": revision(PLUGIN_ROOT),
            "host_git_head": revision(config_root),
            "runs_per_condition": args.runs,
            "fixture_seed": 20260912,
            "conditions_interleaved": True,
            "host_init": str(config_root / "init.lua"),
            "plugin_free_mode": "nvim --clean with temporary XDG directories",
            "cache_conditions": {
                "warm": "20 interleaved paired runs; no operating-system cache reset between samples",
                "cold": "not measured; no cache flush was run on the host",
            },
            "fixtures": fixture_inventory(PLUGIN_ROOT / ".bench-output" / "fixtures"),
            "startup_profile_rows_over_5ms": {
                "host": expensive_profile_rows(first_host_log),
                "plugin_free": expensive_profile_rows(first_minimal_log),
            },
        },
        "samples": samples,
        "summary": {
            name: {
                key: summarize(condition_samples, key)
                for key in ("startup_marker_ms", "process_wall_ms", "ui_first_frame_ms", "first_input_state_ms")
            }
            for name, condition_samples in samples.items()
        },
        "limitations": [
            "First frame and first input measure the generic RPC UI harness probe; feature-specific Workbench latency is measured by the UI journeys.",
            "The plugin-free baseline uses the same Neovim executable and machine but disables user configuration and plugins.",
        ],
    }
    report_path = output / "baseline.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"artifacts": str(output), "summary": report["summary"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
