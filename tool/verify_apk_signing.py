#!/usr/bin/env python3
"""Check apksigner certificate output without depending on signer labels."""

import argparse
import re
import sys


def verify_certificate(report: str, expected: str) -> None:
    expected = expected.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Invalid expected signing certificate fingerprint")
    fingerprints = {
        match.group(1).lower()
        for line in report.splitlines()
        if (match := re.fullmatch(
            r".*\bcertificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*", line
        ))
    }
    if fingerprints != {expected}:
        raise ValueError(
            "APK certificate does not match the configured signing identity: "
            f"expected={expected}, actual={','.join(sorted(fingerprints)) or 'missing'}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", required=True)
    args = parser.parse_args()
    try:
        verify_certificate(sys.stdin.read(), args.expected)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
