import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_plan", ROOT / "scripts/check_plan.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class PlanValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/PLAN.md").write_text("### WB-01\n\n### WB-02\n", encoding="utf-8")
        task = {
            "id": "WB-01", "title": "Fixture task", "owner": "workbench",
            "repositories": ["workbench"], "allowed_paths": {"workbench": ["lua/"]},
            "depends_on": [], "gates": ["G0", "G1"], "spec": "docs/PLAN.md#wb-01",
            "status": "todo", "assignee": None, "evidence": [], "blocker": None,
        }
        self.data = {
            "schema_version": 1, "repositories": ["workbench"],
            "gate_ids": sorted(checker.GATES), "milestones": {"fixture": ["WB-01"]},
            "tasks": [task],
        }

    def errors(self):
        return checker.validate(self.data, self.root)

    def add_dependent(self):
        task = copy.deepcopy(self.data["tasks"][0])
        task.update(id="WB-02", spec="docs/PLAN.md#wb-02", depends_on=["WB-01"])
        self.data["tasks"].append(task)
        self.data["milestones"]["fixture"].append("WB-02")
        return task

    def evidence(self, task, statuses=("pass", "pass")):
        name = f"docs/{task['id']}.json"
        document = {
            "task": task["id"], "revision": "fixture-revision", "environment": "test fixture",
            "summary": "Synthetic evidence for validation tests only",
            "gates": [dict(id=gate, status=status, command="fixture procedure",
                           result="fixture observation", artifacts=[])
                      for gate, status in zip(("G0", "G1"), statuses)],
        }
        (self.root / name).write_text(json.dumps(document), encoding="utf-8")
        task.update(status="done", assignee="fixture", evidence=[name])

    def test_todo_plan_is_valid_but_only_initial_task_ready(self):
        self.add_dependent()
        self.assertEqual(self.errors(), [])
        self.assertEqual([x["id"] for x in checker.ready_tasks(self.data)], ["WB-01"])

    def test_done_without_evidence_rejected(self):
        self.data["tasks"][0].update(status="done", assignee="fixture")
        self.assertTrue(any("missing passing evidence" in x for x in self.errors()))

    def test_done_with_incomplete_dependency_rejected(self):
        self.evidence(self.add_dependent())
        self.assertTrue(any("unfinished dependency" in x for x in self.errors()))

    def test_skipped_required_gate_cannot_complete_task(self):
        self.evidence(self.data["tasks"][0], ("pass", "skip"))
        self.assertTrue(any("is skip" in x for x in self.errors()))

    def test_valid_evidence_unblocks_next_task(self):
        self.add_dependent()
        self.evidence(self.data["tasks"][0])
        self.assertEqual(self.errors(), [])
        self.assertEqual([x["id"] for x in checker.ready_tasks(self.data)], ["WB-02"])

    def test_cycle_rejected(self):
        self.add_dependent()
        self.data["tasks"][0]["depends_on"] = ["WB-02"]
        self.assertTrue(any("cycle" in x for x in self.errors()))

    def test_unknown_owner_rejected(self):
        self.data["tasks"][0]["owner"] = "someone-else"
        self.assertTrue(any("owner" in x for x in self.errors()))

    def test_evidence_path_escape_rejected(self):
        self.data["tasks"][0]["evidence"] = ["../outside.json"]
        self.assertTrue(any("escapes repository" in x for x in self.errors()))

    def test_deferred_task_requires_reason_and_is_not_ready(self):
        self.data["tasks"][0]["status"] = "deferred"
        self.assertTrue(any("needs a reason" in x for x in self.errors()))
        self.data["tasks"][0]["blocker"] = "A later capability"
        self.assertEqual(self.errors(), [])
        self.assertEqual(checker.ready_tasks(self.data), [])

    def test_missing_milestone_dependency_rejected(self):
        self.add_dependent()
        self.data["milestones"]["fixture"] = ["WB-02"]
        self.assertTrue(any("missing dependencies" in x for x in self.errors()))

    def test_duplicate_task_rejected(self):
        self.data["tasks"].append(copy.deepcopy(self.data["tasks"][0]))
        self.assertTrue(any("duplicate task ID" in x for x in self.errors()))

    def test_missing_owned_repository_paths_rejected(self):
        self.data["tasks"][0]["allowed_paths"] = {}
        self.assertTrue(any("allowed_paths" in x for x in self.errors()))

    def test_wrong_evidence_identity_rejected(self):
        task = self.data["tasks"][0]
        self.evidence(task)
        path = self.root / task["evidence"][0]
        document = json.loads(path.read_text(encoding="utf-8"))
        document["task"] = "WB-02"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertTrue(any("ID mismatch" in x for x in self.errors()))

    def test_cli_rejects_unfinished_milestone(self):
        (self.root / "docs/tasks.json").write_text(json.dumps(self.data), encoding="utf-8")
        for name in ("README.md", "AGENTS.md"):
            (self.root / name).write_text("Fixture document\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/check_plan.py"), "--root", str(self.root),
             "--milestone", "fixture"], capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Milestone incomplete", result.stderr)

    def test_real_package_links_and_manifest(self):
        self.assertEqual(checker.validate(checker.read_json(ROOT / "docs/tasks.json"), ROOT), [])
        self.assertEqual(checker.check_links(ROOT), [])


if __name__ == "__main__":
    unittest.main()
