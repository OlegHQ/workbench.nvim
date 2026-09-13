#!/usr/bin/env python3
"""Generate deterministic benchmark workspaces outside tracked source files."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import stat
import time
from pathlib import Path


TIERS = {
    "tiny": (100, 2048),
    "normal": (10_000, 2048),
    "stress": (100_000, 2048),
    "pathological": (20_000, 96),
}
DEFAULT_ROOT = Path(__file__).resolve().parents[1] / ".bench-output" / "fixtures"


def content(seed: int, index: int, size: int, matched: bool) -> bytes:
    digest = hashlib.sha256(f"{seed}:{index}".encode()).hexdigest()
    marker = "MATCH dense-token" if matched else "ordinary no-hit-token"
    header = f"seed={seed} index={index} {marker} digest={digest}\n".encode()
    repeated = (header + f"row={index} payload={digest}\n".encode())
    return (repeated * ((size + len(repeated) - 1) // len(repeated)))[:size]


def make_fixture(tier: str, output: Path, seed: int) -> dict[str, object]:
    count, bytes_per_file = TIERS[tier]
    output.mkdir(parents=True, exist_ok=False)
    root = output / "workspace"
    files_root = root / "files"
    no_match_root = root / "no-match"
    ignored_root = root / "ignored"
    files_root.mkdir(parents=True)
    no_match_root.mkdir()
    ignored_root.mkdir()
    (root / ".gitignore").write_text("ignored/\n", encoding="utf-8")

    generated = 0
    byte_count = 0
    for index in range(count):
        if tier == "pathological":
            directory = root
            name = f"sibling-{index:05d}.txt"
            size = bytes_per_file
            matched = index % 5 == 0
        else:
            ignored = index % 10 == 0
            matched = index % 20 != 1
            base = ignored_root if ignored else (files_root if matched else no_match_root)
            directory = base / f"batch-{index // 1000:04d}"
            directory.mkdir(exist_ok=True)
            name = f"file-{index:06d}.txt"
            size = bytes_per_file
        path = directory / name
        data = content(seed, index, size, matched)
        path.write_bytes(data)
        generated += 1
        byte_count += len(data)

    if tier == "pathological":
        (root / "single-10MiB-line.txt").write_bytes(b"x" * (10 * 1024 * 1024))
        byte_count += 10 * 1024 * 1024

    (root / "line\nbreak.txt").write_text("newline filename\n", encoding="utf-8")
    empty_ignored = ignored_root / "empty"
    empty_ignored.mkdir()
    cycle_link = files_root / "cycle"
    outside = output / "outside-target"
    outside.mkdir()
    (outside / "external.txt").write_text("outside root\n", encoding="utf-8")
    symlink_results: dict[str, str] = {}
    for link, target in ((cycle_link, files_root), (root / "external-link", outside)):
        try:
            link.symlink_to(target, target_is_directory=True)
            symlink_results[str(link.relative_to(root))] = "created"
        except (OSError, NotImplementedError) as error:
            symlink_results[str(link.relative_to(root))] = f"unavailable: {error}"

    inaccessible = root / "inaccessible"
    inaccessible.mkdir()
    inaccessible.chmod(stat.S_IXUSR)
    metadata = {
        "tier": tier,
        "seed": seed,
        "files": generated,
        "content_bytes": byte_count,
        "bytes_per_file": bytes_per_file,
        "workspace": str(root.resolve()),
        "match_rule": "index modulo 20 is not 1, excluding ignored/",
        "cases": {
            "ignored_files": generated // 10 if tier != "pathological" else 0,
            "no_match_files": sum(1 for index in range(count) if index % 20 == 1) if tier != "pathological" else 0,
            "symlinks": symlink_results,
            "unreadable_directory_mode": oct(inaccessible.stat().st_mode & 0o777),
            "ignored_empty_directory": str(empty_ignored.relative_to(root)),
            "newline_filename": "line\\nbreak.txt",
        },
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    metadata_path = output / "fixture.json"
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tier", choices=tuple(TIERS), required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--seed", type=int, default=20260912)
    args = parser.parse_args()
    output = args.output
    if output is None:
        output = DEFAULT_ROOT / f"{args.tier}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{secrets.token_hex(3)}"
    try:
        metadata = make_fixture(args.tier, output, args.seed)
    except FileExistsError:
        parser.error(f"refusing to overwrite existing fixture directory: {output}")
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
