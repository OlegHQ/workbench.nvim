#!/usr/bin/env python3
"""Measure real libuv directory enumeration with 20k immediate siblings."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import pynvim

ROOT = Path(__file__).resolve().parents[2]
ENTRY_COUNT = 20_000
TRIALS = 5


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction + 0.5))]


def run(nvim: str, output: Path) -> dict[str, Any]:
    if os.sep in nvim or (os.altsep and os.altsep in nvim):
        nvim = str(Path(nvim).resolve())
    else:
        nvim = shutil.which(nvim) or str(Path(nvim).resolve())
    output.mkdir(parents=True, exist_ok=False)
    fixture = tempfile.TemporaryDirectory(prefix="wb07-20k-")
    workspace = Path(fixture.name) / "workspace"
    workspace.mkdir()
    started = time.perf_counter()
    for index in range(ENTRY_COUNT):
        (workspace / f"entry-{index:05d}.lua").touch()
    fixture_ms = (time.perf_counter() - started) * 1000

    xdg = tempfile.TemporaryDirectory(prefix="wb07-stress-xdg-")
    xdg_root = Path(xdg.name)
    for name in ("config", "data", "state", "cache"):
        (xdg_root / name).mkdir()
    environment = os.environ.copy()
    environment.update({
        "XDG_CONFIG_HOME": str(xdg_root / "config"),
        "XDG_DATA_HOME": str(xdg_root / "data"),
        "XDG_STATE_HOME": str(xdg_root / "state"),
        "XDG_CACHE_HOME": str(xdg_root / "cache"),
        "GIT_CONFIG_NOSYSTEM": "1",
    })
    socket = f"/tmp/wb07-stress-{secrets.token_hex(8)}.sock"
    command = [
        nvim,
        "--clean",
        "--headless",
        "--listen",
        socket,
        "--cmd",
        f"set runtimepath^={ROOT}",
    ]
    proc: subprocess.Popen[str] | None = None
    control = None
    failure: str | None = None
    samples: list[float] = []
    outcome: dict[str, Any] = {}
    try:
        proc = subprocess.Popen(command, cwd=fixture.name, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 8
        while not Path(socket).exists():
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                raise RuntimeError(f"Neovim exited before RPC listen: {stdout}\n{stderr}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Neovim RPC socket did not appear")
            time.sleep(0.01)
        control = pynvim.attach("socket", path=socket)
        control.exec_lua(
            "local args=...; local root=args[1]; local Workspace=require('workbench.services.workspace'); "
            "_G.wb07_stress_workspace=assert(Workspace.new({root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},ignore_service={snapshot=function() return {hidden='exclude',ignored='include',symlinks='never',include={},exclude={}} end}})); "
            "_G.wb07_stress_snapshot=assert(_G.wb07_stress_workspace:open({explicit_root=root})); "
            "_G.wb07_stress_provider=assert(require('workbench.providers.filesystem').new()); _G.wb07_stress_results={}",
            [str(workspace)],
        )

        for trial in range(TRIALS):
            control.exec_lua(
                "local args=...; local trial=args[1]; local provider=_G.wb07_stress_provider; "
                "provider:invalidate(_G.wb07_stress_snapshot.roots[1].path); "
                "local result={count=0,first={},last={},started=(vim.uv or vim.loop).hrtime()}; _G.wb07_stress_results[trial]=result; "
                "local request,err=provider:enumerate(_G.wb07_stress_snapshot,_G.wb07_stress_snapshot.roots[1].path,{refresh=true},function(event) "
                "if event.kind=='batch' then result.count=#event.items; for i=1,math.min(5,#event.items) do result.first[i]=event.items[i].payload.raw_name end; "
                "for i=math.max(1,#event.items-4),#event.items do result.last[#result.last+1]=event.items[i].payload.raw_name end "
                "elseif event.kind=='done' then result.completeness=event.completeness; result.elapsed_ms=((vim.uv or vim.loop).hrtime()-result.started)/1000000 "
                "elseif event.kind=='error' then result.error=event.error end end); "
                "if not request then result.error=err end",
                [trial + 1],
            )
            wait_deadline = time.monotonic() + 45
            while time.monotonic() < wait_deadline:
                done = control.exec_lua(
                    "local args=...; local result=_G.wb07_stress_results[args[1]]; return result and (result.completeness~=nil or result.error~=nil)",
                    [trial + 1],
                )
                if done:
                    break
                time.sleep(0.005)
            else:
                raise TimeoutError(f"20k sibling enumeration timed out on trial {trial + 1}")
            result = control.exec_lua("local args=...; return _G.wb07_stress_results[args[1]]", [trial + 1])
            if result.get("error"):
                raise RuntimeError(f"filesystem provider failed on trial {trial + 1}: {result['error']}")
            if result.get("completeness") != "complete" or result.get("count") != ENTRY_COUNT:
                raise AssertionError(f"incomplete 20k sibling result on trial {trial + 1}: {result}")
            if result.get("first") != [f"entry-{index:05d}.lua" for index in range(5)]:
                raise AssertionError(f"unstable sorted first entries on trial {trial + 1}: {result.get('first')}")
            if result.get("last") != [f"entry-{index:05d}.lua" for index in range(ENTRY_COUNT - 5, ENTRY_COUNT)]:
                raise AssertionError(f"unstable sorted last entries on trial {trial + 1}: {result.get('last')}")
            samples.append(float(result["elapsed_ms"]))

        outcome = {
            "fixture_entries": ENTRY_COUNT,
            "fixture_creation_ms": round(fixture_ms, 3),
            "provider_elapsed_ms": [round(sample, 3) for sample in samples],
            "provider_p50_ms": round(statistics.median(samples), 3),
            "provider_p95_ms": round(percentile(samples, 0.95), 3),
            "provider_max_ms": round(max(samples), 3),
            "result_count": ENTRY_COUNT,
            "completeness": "complete",
            "stable_order_first_last": True,
        }
        control.exec_lua("_G.wb07_stress_provider:dispose()")
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        raise
    finally:
        if proc and proc.poll() is None and control is not None:
            try:
                control.command("qa!", async_=True)
            except Exception:
                pass
        if proc and proc.poll() is None:
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.terminate()
        if proc and proc.poll() is None:
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        returncode = proc.wait(timeout=3) if proc else None
        if control is not None:
            try:
                control.close()
            except Exception:
                pass
        Path(socket).unlink(missing_ok=True)
        version = subprocess.run([nvim, "--version"], text=True, capture_output=True, timeout=3, check=False)
        metadata = {
            "nvim": nvim,
            "nvim_version": version.stdout.splitlines()[0] if version.stdout else "unavailable",
            "command": command,
            "workbench_head": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True, capture_output=True, check=False).stdout.strip(),
            "returncode": returncode,
            "failure": failure,
            "outcome": outcome,
        }
        (output / ("failure.json" if failure else "result.json")).write_text(json.dumps(metadata, indent=2) + "\n")
        xdg.cleanup()
        fixture.cleanup()
    return outcome


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb07-stress")
    args = parser.parse_args()
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    output = args.output_root / f"{stamp}-{secrets.token_hex(3)}"
    try:
        outcome = run(args.nvim, output)
    except Exception as error:
        print(f"WB-07 20k sibling stress failed; artifacts: {output}\n{type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"artifacts": str(output), **outcome}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
