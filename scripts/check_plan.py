#!/usr/bin/env python3
"""Validate planning structure and evidence references, not runtime correctness."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


STATUSES = {"todo", "in_progress", "blocked", "deferred", "done"}
GATES = {f"G{i}" for i in range(8)}


def local_path(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ValueError("expected a repository-relative path")
    result = (root / value).resolve()
    if not result.is_relative_to(root.resolve()):
        raise ValueError("path escapes repository")
    return result


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def validate_evidence(root, task, errors):
    passed = set()
    for reference in task.get("evidence", []):
        try:
            evidence = read_json(local_path(root, reference))
            if not isinstance(evidence, dict) or evidence.get("task") != task["id"]:
                raise ValueError("evidence task ID mismatch")
            for key in ("revision", "environment", "summary"):
                if not isinstance(evidence.get(key), str) or not evidence[key].strip():
                    raise ValueError(f"missing evidence {key}")
            records = evidence.get("gates")
            if not isinstance(records, list) or not records:
                raise ValueError("evidence gates must be a nonempty list")
            seen = set()
            for gate in records:
                if not isinstance(gate, dict) or gate.get("id") not in GATES:
                    raise ValueError("unknown evidence gate")
                if gate["id"] in seen:
                    raise ValueError("duplicate gate within evidence")
                seen.add(gate["id"])
                if gate.get("status") not in {"pass", "fail", "skip"}:
                    raise ValueError("invalid evidence gate status")
                for key in ("command", "result"):
                    if not isinstance(gate.get(key), str) or not gate[key].strip():
                        raise ValueError(f"missing gate {key}")
                artifacts = gate.get("artifacts")
                if not isinstance(artifacts, list):
                    raise ValueError("artifacts must be a list")
                for artifact in artifacts:
                    if not local_path(root, artifact).is_file():
                        raise ValueError(f"missing artifact {artifact}")
                if gate["status"] == "pass":
                    passed.add(gate["id"])
                elif task["status"] == "done" and gate["id"] in task["gates"]:
                    errors.append(f"{task['id']}: required gate {gate['id']} is {gate['status']}")
        except (OSError, ValueError, TypeError, KeyError) as exc:
            errors.append(f"{task['id']}: invalid evidence {reference}: {exc}")
    if task["status"] == "done":
        missing = set(task.get("gates", [])) - passed
        if missing:
            errors.append(f"{task['id']}: missing passing evidence for {sorted(missing)}")


def validate(data, root):
    errors = []
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        return ["unsupported manifest schema"]
    repos = data.get("repositories", [])
    if not isinstance(repos, list) or not repos or not all(isinstance(x, str) for x in repos):
        return ["repositories must be a nonempty string list"]
    if data.get("gate_ids") != sorted(GATES):
        errors.append("gate_ids must declare G0 through G7")
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        return errors + ["tasks must be a nonempty list"]
    by_id = {}
    for task in tasks:
        if not isinstance(task, dict) or not re.fullmatch(r"WB-\d{2}", str(task.get("id", ""))):
            errors.append("invalid task ID")
            continue
        tid = task["id"]
        if tid in by_id:
            errors.append(f"duplicate task ID {tid}")
        by_id[tid] = task
        for key in ("title", "owner", "spec"):
            if not isinstance(task.get(key), str) or not task[key].strip():
                errors.append(f"{tid}: missing {key}")
        for key in ("depends_on", "gates", "repositories", "evidence"):
            value = task.get(key)
            if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
                errors.append(f"{tid}: {key} must be a string list")
                task[key] = []
            elif len(value) != len(set(value)):
                errors.append(f"{tid}: duplicate values in {key}")
        if task.get("owner") not in repos or task.get("owner") not in task["repositories"]:
            errors.append(f"{tid}: invalid primary owner")
        if set(task["repositories"]) - set(repos):
            errors.append(f"{tid}: unknown repository")
        if not task["gates"] or set(task["gates"]) - GATES or "G0" not in task["gates"]:
            errors.append(f"{tid}: invalid gates or missing ownership gate")
        paths = task.get("allowed_paths")
        if not isinstance(paths, dict) or set(paths) != set(task["repositories"]):
            errors.append(f"{tid}: allowed_paths must cover exactly its repositories")
        else:
            for repo, entries in paths.items():
                if not isinstance(entries, list) or not entries:
                    errors.append(f"{tid}: missing owned paths for {repo}")
                    continue
                for entry in entries:
                    try:
                        local_path(root, entry)
                    except (ValueError, TypeError) as exc:
                        errors.append(f"{tid}: invalid owned path: {exc}")
        status = task.get("status")
        if status not in STATUSES:
            errors.append(f"{tid}: invalid status")
        if status in {"in_progress", "done"} and not task.get("assignee"):
            errors.append(f"{tid}: active/completed task needs an assignee")
        if status in {"blocked", "deferred"} and not task.get("blocker"):
            errors.append(f"{tid}: blocked/deferred task needs a reason")
        try:
            file_name, anchor = task.get("spec", "").split("#", 1)
            body = local_path(root, file_name).read_text(encoding="utf-8")
            if anchor != tid.lower() or f"### {tid}\n" not in body:
                raise ValueError("missing task section or wrong anchor")
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            errors.append(f"{tid}: invalid spec: {exc}")
        if status in STATUSES:
            validate_evidence(root, task, errors)

    visiting, visited = set(), set()

    def visit(tid):
        if tid in visiting:
            errors.append(f"dependency cycle at {tid}")
            return
        if tid in visited:
            return
        visiting.add(tid)
        for dep in by_id[tid].get("depends_on", []):
            if dep not in by_id:
                errors.append(f"{tid}: unknown dependency {dep}")
            else:
                if by_id[tid].get("status") == "done" and by_id[dep].get("status") != "done":
                    errors.append(f"{tid}: unfinished dependency {dep}")
                visit(dep)
        visiting.remove(tid)
        visited.add(tid)

    for tid in by_id:
        visit(tid)
    milestones = data.get("milestones")
    if not isinstance(milestones, dict) or not milestones:
        errors.append("milestones must be a nonempty object")
    else:
        for name, members in milestones.items():
            if not isinstance(members, list) or not members or not all(isinstance(x, str) for x in members):
                errors.append(f"{name}: invalid milestone members")
                continue
            if len(members) != len(set(members)):
                errors.append(f"{name}: duplicate milestone members")
            for tid in members:
                if tid not in by_id:
                    errors.append(f"{name}: unknown task {tid}")
                elif set(by_id[tid].get("depends_on", [])) - set(members):
                    errors.append(f"{name}: missing dependencies of {tid}")
    return errors


def check_links(root):
    """Check local destinations in this package's inline Markdown links."""
    errors = []
    paths = list((root / "docs").rglob("*.md")) + list((root / ".agents").rglob("*.md"))
    paths += [root / "README.md", root / "AGENTS.md"]
    for path in paths:
        if not path.is_file():
            errors.append(f"missing document {path.relative_to(root)}")
            continue
        body = re.sub(r"```.*?```", "", path.read_text(encoding="utf-8"), flags=re.S)
        for target in re.findall(r"\]\(([^)]+)\)", body):
            parsed = urlsplit(target.strip("<>"))
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            destination = (path.parent / unquote(parsed.path)).resolve()
            if not destination.is_relative_to(root.resolve()) or not destination.is_file():
                errors.append(f"{path.relative_to(root)}: invalid local link {target}")
    return errors


def ready_tasks(data):
    statuses = {task["id"]: task["status"] for task in data["tasks"]}
    return [task for task in data["tasks"] if task["status"] == "todo"
            and all(statuses[dep] == "done" for dep in task["depends_on"])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--next", action="store_true", help="list dependency-ready tasks")
    parser.add_argument("--milestone", help="require all tasks in the named milestone done")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        data = read_json(root / "docs/tasks.json")
        errors = validate(data, root) + check_links(root)
    except (OSError, ValueError, TypeError) as exc:
        errors = [str(exc)]
    if errors:
        print("Planning validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Planning structure valid. Runtime gates are not independently assessed by this checker.")
    if args.milestone:
        if args.milestone not in data["milestones"]:
            print(f"Unknown milestone: {args.milestone}", file=sys.stderr)
            return 2
        statuses = {task["id"]: task["status"] for task in data["tasks"]}
        pending = [tid for tid in data["milestones"][args.milestone] if statuses[tid] != "done"]
        if pending:
            print(f"Milestone incomplete: {', '.join(pending)}", file=sys.stderr)
            return 2
        print(f"Milestone records complete: {args.milestone}; inspect evidence before release.")
    if args.next:
        ready = ready_tasks(data)
        for task in ready:
            print(f"{task['id']}: {task['title']} (owner: {task['owner']})")
        if not ready:
            print("No todo tasks are dependency-ready; inspect active, blocked and deferred tasks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
