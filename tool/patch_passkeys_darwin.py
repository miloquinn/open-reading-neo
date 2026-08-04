#!/usr/bin/env python3
"""Patch passkeys_darwin for Apple SDKs that predate Credential Data Manager."""

from __future__ import annotations

import os
from pathlib import Path


VERSION = "0.4.2+2"
EXPECTED_SHA256 = "32077a8fcda5f52338dd430ed854b05cf131bbb0df7ee7027ca4e43400164779"
RELATIVE_SOURCE = Path(
    "darwin/passkeys_darwin/Sources/passkeys_darwin/PasskeysPlugin.swift"
)


def replace_method(source: str, signature: str, next_signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"passkeys_darwin patch target is missing: {signature}")
    end = source.find(next_signature, start)
    if end < 0:
        raise SystemExit(f"passkeys_darwin patch boundary is missing: {next_signature}")
    replacement = f"""{signature}
        // passkeys_darwin 0.4.2+2 references ASCredentialDataManager, an API
        // unavailable in the Xcode 16 SDK used by the release runners. These
        // signals are optional hints and are safe to ignore on older SDKs.
        completion(.success(()))
    }}

    """
    return source[:start] + replacement + source[end:]


def main() -> None:
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
    package = pub_cache / "hosted" / "pub.dev" / f"passkeys_darwin-{VERSION}"
    source_path = package / RELATIVE_SOURCE
    if not source_path.is_file():
        raise SystemExit(f"expected passkeys_darwin source was not found: {source_path}")

    lockfile = Path("pubspec.lock").read_text(encoding="utf-8")
    expected_lock_entry = (
        "  passkeys_darwin:\n"
        "    dependency: transitive\n"
        "    description:\n"
        "      name: passkeys_darwin\n"
        f'      sha256: "{EXPECTED_SHA256}"\n'
    )
    if expected_lock_entry not in lockfile or f'    version: "{VERSION}"' not in lockfile:
        raise SystemExit("pubspec.lock no longer matches the reviewed passkeys_darwin release")

    source = source_path.read_text(encoding="utf-8")
    if "ASCredentialDataManager" not in source:
        print("passkeys_darwin does not need the Xcode 16 compatibility patch")
        return

    source = replace_method(
        source,
        "    func signalUnknownCredential(relyingPartyId: String, credentialId: String, completion: @escaping (Result<Void, Error>) -> Void) {",
        "    func signalAllAcceptedCredentials(",
    )
    source = replace_method(
        source,
        "    func signalAllAcceptedCredentials(relyingPartyId: String, userId: String, allAcceptedCredentialIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {",
        "    private func parseCredentials(",
    )
    source_path.write_text(source, encoding="utf-8")
    print(f"patched {source_path}")


if __name__ == "__main__":
    main()
