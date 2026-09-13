from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "tests" / "check_ownership.py"
SPEC = importlib.util.spec_from_file_location("check_ownership", CHECKER)
assert SPEC and SPEC.loader
CHECKER_MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER_MODULE
SPEC.loader.exec_module(CHECKER_MODULE)


class OwnershipGuardTests(unittest.TestCase):
    def make_tree(self, root: Path) -> None:
        (root / "lua" / "workbench" / "core").mkdir(parents=True)
        (root / "tests" / "runtime").mkdir(parents=True)
        (root / "tests" / "runtime" / "require_allowlist.json").write_text("[]\n")

    def test_allowed_core_dependency_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_tree(root)
            (root / "lua" / "workbench" / "core" / "model.lua").write_text(
                'local item = require("workbench.core.item")\nreturn item\n'
            )
            self.assertEqual(CHECKER_MODULE.inspect(root), [])

    def test_ui_internal_composition_is_allowed_but_provider_import_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_tree(root)
            ui = root / "lua" / "workbench" / "ui"
            ui.mkdir()
            (ui / "layout.lua").write_text('require("workbench.ui.view")\n')
            (ui / "view.lua").write_text('require("workbench.ui.projection")\n')
            self.assertEqual(CHECKER_MODULE.inspect(root), [])
            (ui / "bad.lua").write_text('require("workbench.providers.fs")\n')
            self.assertIn("ui may not import workbench.providers", CHECKER_MODULE.inspect(root)[0])

    def test_forbidden_provider_to_ui_dependency_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_tree(root)
            provider = root / "lua" / "workbench" / "providers"
            provider.mkdir()
            (provider / "fs.lua").write_text('require("workbench.ui.tree")\n')
            self.assertIn("providers may not import workbench.ui", CHECKER_MODULE.inspect(root)[0])

    def test_dynamic_require_requires_exact_review_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_tree(root)
            source = root / "lua" / "workbench" / "core" / "dynamic.lua"
            source.write_text("local module_name = 'x'\nrequire(module_name)\n")
            self.assertIn("dynamic require is not in the reviewed allowlist", CHECKER_MODULE.inspect(root)[0])
            allowlist = root / "tests" / "runtime" / "require_allowlist.json"
            allowlist.write_text(json.dumps(["lua/workbench/core/dynamic.lua:2"]))
            self.assertEqual(CHECKER_MODULE.inspect(root), [])

    def test_cli_returns_nonzero_for_broken_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_tree(root)
            provider = root / "lua" / "workbench" / "providers"
            provider.mkdir()
            (provider / "bad.lua").write_text('require("workbench.controllers.files")\n')
            result = subprocess.run(
                [sys.executable, str(CHECKER), "--root", str(root)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("ownership check failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
