#!/usr/bin/env python3
"""Guard literal workbench imports against the architecture dependency rules."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


AREAS = {"core", "services", "providers", "controllers", "ui", "adapters"}
FORBIDDEN = {
    "core": {"services", "providers", "controllers", "ui", "adapters", "compose"},
    "services": {"services", "providers", "controllers", "ui", "adapters", "compose"},
    "providers": {"services", "providers", "controllers", "ui", "adapters", "compose"},
    "controllers": {"controllers", "compose", "adapters"},
    "ui": {"services", "providers", "controllers", "adapters", "compose"},
    "adapters": {"core", "services", "providers", "controllers", "ui", "compose"},
}
LITERAL_REQUIRE = re.compile(r"\brequire\s*\(\s*(['\"])(.*?)\1\s*\)")
ANY_REQUIRE = re.compile(r"\brequire\s*\(")


def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or any(not isinstance(item, str) for item in data):
        raise ValueError(f"{path} must contain a JSON array of path:line entries")
    return set(data)


def inspect(root: Path) -> list[str]:
    source_root = root / "lua" / "workbench"
    allowlist_path = root / "tests" / "runtime" / "require_allowlist.json"
    allowlist = load_allowlist(allowlist_path)
    errors: list[str] = []
    seen_dynamic: set[str] = set()

    if not source_root.exists():
        return []

    for path in sorted(source_root.rglob("*.lua")):
        relative = path.relative_to(root).as_posix()
        parts = path.relative_to(source_root).parts
        source_area = parts[0] if len(parts) > 1 else "public"
        content = path.read_text(encoding="utf-8")
        literal_matches = list(LITERAL_REQUIRE.finditer(content))

        for match in literal_matches:
            module = match.group(2)
            if not module.startswith("workbench."):
                continue
            target = module.removeprefix("workbench.").split(".", 1)[0]
            if target in FORBIDDEN.get(source_area, set()):
                line = content.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line}: {source_area} may not import workbench.{target}")

        literal_starts = {match.start() for match in literal_matches}
        for match in ANY_REQUIRE.finditer(content):
            if match.start() in literal_starts:
                continue
            line = content.count("\n", 0, match.start()) + 1
            key = f"{relative}:{line}"
            seen_dynamic.add(key)
            if key not in allowlist:
                errors.append(f"{key}: dynamic require is not in the reviewed allowlist")

    stale_allowlist = sorted(allowlist - seen_dynamic)
    errors.extend(f"{entry}: stale dynamic-require allowlist entry" for entry in stale_allowlist)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        errors = inspect(root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ownership check failed: {error}", file=sys.stderr)
        return 2
    if errors:
        print("ownership check failed:")
        for error in errors:
            print(f"  {error}")
        return 1
    modules = sum(1 for _ in (root / "lua" / "workbench").rglob("*.lua"))
    print(f"Ownership boundaries valid for {modules} workbench Lua modules; dynamic-require allowlist is reviewed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
