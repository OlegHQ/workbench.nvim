from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MiniTestRunnerFailureTests(unittest.TestCase):
    def test_mini_test_failure_produces_nonzero_exit(self) -> None:
        nvim = os.environ.get("NVIM_TEST_BINARY", str(ROOT / ".test-deps" / "neovim-0.11.7" / "bin" / "nvim"))
        env = os.environ.copy()
        env["WORKBENCH_TEST_DEPS"] = str(ROOT / ".test-deps")
        env["NVIM_TEST_BINARY"] = nvim
        env["WORKBENCH_TEST_FILE"] = str(ROOT / "tests" / "runtime" / "fixtures" / "fail_runner.lua")
        command = [
            nvim,
            "--clean",
            "--headless",
            "-u",
            str(ROOT / "tests" / "runtime" / "minimal_init.lua"),
            "-l",
            str(ROOT / "tests" / "runtime" / "run.lua"),
        ]
        result = subprocess.run(command, env=env, cwd=ROOT, text=True, capture_output=True, timeout=10, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("intentional failure probe", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
