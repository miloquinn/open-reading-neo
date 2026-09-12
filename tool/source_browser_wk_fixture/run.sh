#!/bin/bash
set -euo pipefail

fixture_dir="$(cd "$(dirname "$0")" && pwd)"
temporary_dir="$(mktemp -d /tmp/xxread-wk-fixture.XXXXXX)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  find "$temporary_dir" -type f -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT

python3 "$fixture_dir/server.py" &
server_pid="$!"

for _ in {1..50}; do
  if curl --silent --fail --max-time 1 http://127.0.0.1:18765/ >/dev/null; then
    break
  fi
  sleep 0.1
done

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit \
  -framework WebKit \
  "$fixture_dir/WKFixture.swift" \
  -o "$temporary_dir/WKFixture"

"$temporary_dir/WKFixture"
