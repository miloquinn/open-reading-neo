from __future__ import annotations

import argparse
from pathlib import Path
import sys

from .audit import audit_files, render_json, render_markdown


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit reading-source JSON offline.")
    parser.add_argument("paths", nargs="+", help="JSON files to parse")
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    parser.add_argument("--output", help="write the report to a file instead of stdout")
    args = parser.parse_args(argv)

    report = audit_files(args.paths)
    rendered = render_json(report) if args.format == "json" else render_markdown(report)
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
