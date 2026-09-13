#!/usr/bin/env python3
"""Run the local rg-provider performance probe and sample Neovim RSS."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def sample_process_tree_rss(pid: int) -> int:
    result = subprocess.run(
        ["ps", "-Ao", "pid=,ppid=,rss="],
        check=False,
        text=True,
        capture_output=True,
    )
    total = 0
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        try:
            process_id, parent_id, resident_kib = map(int, fields[:3])
        except ValueError:
            continue
        if process_id == pid or parent_id == pid:
            total += resident_kib
    return total


def run(nvim: str, fixture: Path, repetitions: int) -> dict[str, Any]:
    environment = os.environ.copy()
    environment["WB09_FIXTURE"] = str(fixture.resolve())
    environment["WB09_REPETITIONS"] = str(repetitions)
    command = [nvim, "--clean", "--headless", "-u", "NONE", "-l", str(ROOT / "bench" / "rg_provider.lua")]
    process = subprocess.Popen(command, cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    peak_rss = 0
    while process.poll() is None:
        peak_rss = max(peak_rss, sample_process_tree_rss(process.pid))
        time.sleep(0.1)
    stdout, stderr = process.communicate(timeout=5)
    if process.returncode != 0:
        raise RuntimeError(f"rg provider benchmark failed ({process.returncode}):\n{stderr}\n{stdout}")
    all_lines = [line for line in (stdout + "\n" + stderr).splitlines() if line.strip()]
    output_index = next((index for index in range(len(all_lines) - 1, -1, -1) if all_lines[index].startswith("{")), None)
    if output_index is None:
        raise RuntimeError(f"rg provider benchmark printed no JSON result:\n{stderr}")
    result = json.loads(all_lines[output_index])
    result["nvim_executable"] = nvim
    result["nvim_and_rg_peak_rss_kib"] = peak_rss
    result["rss_sampling_interval_ms"] = 100
    result["stderr"] = "\n".join(line for index, line in enumerate(all_lines) if index != output_index)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = run(args.nvim, args.fixture, args.repetitions)
    rendered = json.dumps(result, indent=2) + "\n"
    if args.output:
        destination = args.output if args.output.is_absolute() else ROOT / args.output
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
