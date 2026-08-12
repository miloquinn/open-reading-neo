#!/usr/bin/env python3
"""Build the in-app changelog catalog from GitHub release-note Markdown files.

Existing localized notes are preserved so translations can be maintained by
hand. New versions use the release-note bullets as the source-language notes;
the Flutter service falls back to those notes until translations are added.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
INLINE_MARKUP_RE = re.compile(r"\*\*(.*?)\*\*|__(.*?)__|`([^`]*)`")
LINK_RE = re.compile(r"\[([^]]+)\]\([^)]*\)")
META_HEADINGS = {
    "版本",
    "版本信息",
    "版本資訊",
    "version",
    "versions",
    "验证",
    "驗證",
    "verification",
}


def version_key(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid release-note version: {version}")
    return tuple(int(part) for part in match.groups())


def clean_item(item: str) -> str:
    item = LINK_RE.sub(r"\1", item)
    item = INLINE_MARKUP_RE.sub(
        lambda match: next(group for group in match.groups() if group is not None),
        item,
    )
    return " ".join(item.split()).strip()


def parse_release_notes(path: Path) -> list[str]:
    """Extract user-facing bullets, excluding version metadata and validation."""
    items: list[str] = []
    skip_section = False
    for line in path.read_text(encoding="utf-8").splitlines():
        heading = re.match(r"^#{2,6}\s+(.+?)\s*$", line)
        if heading:
            title = clean_item(heading.group(1)).rstrip(":").lower()
            skip_section = title in META_HEADINGS
            continue
        if skip_section:
            continue
        bullet = re.match(r"^\s*[-*+]\s+(.+?)\s*$", line)
        if bullet:
            item = clean_item(bullet.group(1))
            if item:
                items.append(item)
    if not items:
        raise ValueError(f"No release-note bullets found in {path}")
    return items


def load_catalog(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schemaVersion": 1, "entries": []}
    catalog = json.loads(path.read_text(encoding="utf-8"))
    if catalog.get("schemaVersion") != 1 or not isinstance(catalog.get("entries"), list):
        raise ValueError(f"Unsupported changelog catalog: {path}")
    return catalog


def build_catalog(notes_dir: Path, existing: dict[str, Any]) -> dict[str, Any]:
    existing_entries = {
        entry["version"]: entry
        for entry in existing["entries"]
        if isinstance(entry, dict) and isinstance(entry.get("version"), str)
    }
    markdown_entries: dict[str, dict[str, Any]] = {}
    for path in notes_dir.glob("v*.md"):
        version = path.stem[1:]
        version_key(version)
        markdown_entries[version] = {
            "version": version,
            "notes": {"zh": parse_release_notes(path)},
        }

    # Markdown releases are authoritative for coverage, while legacy catalog
    # entries without a corresponding file remain available for old versions.
    versions = sorted(
        set(existing_entries) | set(markdown_entries),
        key=version_key,
        reverse=True,
    )
    entries: list[dict[str, Any]] = []
    for version in versions:
        if version in existing_entries:
            entry = existing_entries[version]
            if version in markdown_entries:
                notes = dict(entry.get("notes", {}))
                notes.setdefault("zh", markdown_entries[version]["notes"]["zh"])
                entry = {"version": version, "notes": notes}
            entries.append(entry)
        else:
            entries.append(markdown_entries[version])
    return {"schemaVersion": 1, "entries": entries}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the catalog is stale")
    parser.add_argument("--notes-dir", type=Path, default=Path(".github/release-notes"))
    parser.add_argument("--output", type=Path, default=Path("assets/changelog/changelog.json"))
    args = parser.parse_args()

    generated = build_catalog(args.notes_dir, load_catalog(args.output))
    rendered = json.dumps(generated, ensure_ascii=False, indent=4) + "\n"
    current = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
    if args.check:
        if current != rendered:
            print(f"{args.output} is stale; run tool/generate_changelog.py", file=sys.stderr)
            return 1
        return 0
    args.output.write_text(rendered, encoding="utf-8")
    print(f"Wrote {len(generated['entries'])} changelog entries to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
