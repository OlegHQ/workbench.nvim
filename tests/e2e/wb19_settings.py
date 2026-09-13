#!/usr/bin/env python3
"""Exercise registered settings actions through the real palette UI."""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run  # noqa: E402


class SettingsRun(Run):
    def _start(self):
        super()._start()
        self.lua(
            "local Scope=require('workbench.core.scope'); "
            "_G.wb19_settings=assert(require('workbench.services.settings').new()); "
            "assert(_G.wb19_settings:configure({enabled=true})); "
            "_G.wb19_scope=Scope.new('wb19-ui-settings'); "
            "_G.wb19_controller=assert(require('workbench.controllers.settings').new({"
            "settings=_G.wb19_settings,actions=_G.wb10_actions,scope=_G.wb19_scope})); "
            "_G.wb19_values={completion=false,formatting=false,diagnostics=false}; "
            "_G.wb19_attach_adapters=function() _G.wb19_handles={}; "
            "for _,id in ipairs({'completion','formatting','diagnostics'}) do "
            "local adapter={scope='global',capabilities=function() return {available=true,state='ready'} end,"
            "get=function() local v=_G.wb19_values[id]; return {requested=v,effective=v,provenance='e2e-host'} end,"
            "set=function(value) _G.wb19_values[id]=value; return true end}; "
            "_G.wb19_handles[#_G.wb19_handles+1]=assert(_G.wb19_settings:register_adapter(id,adapter,{scope=_G.wb19_scope})) end end; "
            "return true"
        )

    def _open_palette_action(self, action_id: str, title: str):
        self.lua("_G.wb10_controller.palette:open({focus=true})")
        self.wait_screen("Actions · Enter runs")
        self.prompt("/", action_id, "Filter actions:")
        self.wait_screen(title)

    def _exercise(self):
        assert self.control is not None
        action_timings = {}
        self.phase = "standalone-adapter-unavailable"
        missing = self.lua(
            "local s=_G.wb19_settings:adapter_state('completion'); "
            "return {available=s.available,reason=s.reason,focus=vim.api.nvim_get_current_win()}"
        )
        if missing["available"] or "no autoconf editor-setting adapter" not in missing["reason"]:
            raise AssertionError(f"standalone host adapter was not accurately unavailable: {missing}")
        origin_view = self.lua("return _G.wb10_origin_win")
        self._open_palette_action("settings.toggle_completion", "Toggle completion")
        self.input("\r")
        self.wait_screen("no autoconf editor-setting adapter")
        self.input("q")
        self.lua("_G.wb19_attach_adapters()")

        self.phase = "completion-palette-toggle-and-checked-state"
        self._open_palette_action("settings.toggle_completion", "Toggle completion")
        started = time.perf_counter_ns()
        self.input("\r")
        self.wait_lua("return _G.wb19_values.completion==true", "completion setting changes through action UI")
        action_timings["completion_ms"] = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_lua(f"return vim.api.nvim_get_current_win()=={origin_view}", "palette returns focus to the user's editor")
        self._open_palette_action("settings.toggle_completion", "Toggle completion")
        self.wait_screen("on")
        self.input("q")

        self.phase = "formatting-and-diagnostics-palette-toggles"
        self._open_palette_action("settings.toggle_formatting", "Toggle format on save")
        started = time.perf_counter_ns()
        self.input("\r")
        self.wait_lua("return _G.wb19_values.formatting==true", "formatting setting changes through action UI")
        action_timings["formatting_ms"] = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_lua(f"return vim.api.nvim_get_current_win()=={origin_view}", "formatting palette restores focus")
        self._open_palette_action("settings.toggle_diagnostics", "Toggle inline diagnostics")
        started = time.perf_counter_ns()
        self.input("\r")
        self.wait_lua("return _G.wb19_values.diagnostics==true", "diagnostics setting changes through action UI")
        action_timings["diagnostics_ms"] = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_lua(f"return vim.api.nvim_get_current_win()=={origin_view}", "diagnostics palette restores focus")

        final = self.lua(
            "local values=_G.wb19_values; local state={}; "
            "for _,id in ipairs({'completion','formatting','diagnostics'}) do state[id]=_G.wb19_settings:adapter_state(id) end; "
            "return {values=values,state=state,search_views=_G.wb10_controller:status().active_views,"
            "palette=_G.wb10_controller.palette:status(),resources=_G.wb19_scope:inventory()}"
        )
        if not all(final["values"].values()):
            raise AssertionError(f"one or more external settings did not take effect: {final}")
        if final["search_views"] != 1 or final["palette"]["active"] != 0:
            raise AssertionError(f"palette actions disturbed sibling Search ownership or remained mounted: {final}")
        if max(action_timings.values()) > 150:
            raise AssertionError(f"a settings action exceeded the 150 ms interaction budget: {action_timings}")
        self.lua("_G.wb19_controller:dispose(); _G.wb19_scope:dispose(); _G.wb19_settings:dispose()")
        self.wait_lua("return _G.wb10_controller:status().active_views==1", "settings disposal leaves Search alive")
        return {"unavailable_reason": missing["reason"], "actions": final["state"],
                "search_views": final["search_views"], "action_timings": action_timings}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="120x35")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb19")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = SettingsRun(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-19 settings UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n"
                  f"{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
