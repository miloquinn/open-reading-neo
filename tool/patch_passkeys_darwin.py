#!/usr/bin/env python3
"""Patch locked Apple plugins that reference symbols newer than Xcode 16."""

from __future__ import annotations

import os
from pathlib import Path


VERSION = "0.4.2+2"
EXPECTED_SHA256 = "32077a8fcda5f52338dd430ed854b05cf131bbb0df7ee7027ca4e43400164779"
DEVICE_INFO_VERSION = "12.4.0"
DEVICE_INFO_SHA256 = "b4fed1b2835da9d670d7bed7db79ae2a94b0f5ad6312268158a9b5479abbacdd"
RELATIVE_SOURCE = Path(
    "darwin/passkeys_darwin/Sources/passkeys_darwin/PasskeysPlugin.swift"
)
DEVICE_INFO_SOURCE = Path(
    "ios/device_info_plus/Sources/device_info_plus/FPPDeviceInfoPlusPlugin.m"
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
    else:
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

    device_package = (
        pub_cache / "hosted" / "pub.dev" / f"device_info_plus-{DEVICE_INFO_VERSION}"
    )
    device_source_path = device_package / DEVICE_INFO_SOURCE
    if not device_source_path.is_file():
        raise SystemExit(
            f"expected device_info_plus source was not found: {device_source_path}"
        )
    expected_device_lock_entry = (
        "  device_info_plus:\n"
        "    dependency: transitive\n"
        "    description:\n"
        "      name: device_info_plus\n"
        f"      sha256: {DEVICE_INFO_SHA256}\n"
    )
    if (
        expected_device_lock_entry not in lockfile
        or f'    version: "{DEVICE_INFO_VERSION}"' not in lockfile
    ):
        raise SystemExit(
            "pubspec.lock no longer matches the reviewed device_info_plus release"
        )

    device_source = device_source_path.read_text(encoding="utf-8")
    vision_block = """    NSNumber *isiOSAppOnVision = [NSNumber numberWithBool:NO];
    if (@available(iOS 26.1, *)) {
      isiOSAppOnVision = [NSNumber numberWithBool:[info isiOSAppOnVision]];
    }
"""
    if vision_block in device_source:
        device_source = device_source.replace(
            vision_block,
            """    // Xcode 16's SDK does not declare isiOSAppOnVision. Keep the
    // additive field false until the release runner adopts the iOS 26 SDK.
    NSNumber *isiOSAppOnVision = [NSNumber numberWithBool:NO];
""",
            1,
        )
        device_source_path.write_text(device_source, encoding="utf-8")
        print(f"patched {device_source_path}")
    elif "[info isiOSAppOnVision]" in device_source:
        raise SystemExit("device_info_plus Vision compatibility block changed")
    else:
        print("device_info_plus does not need the Xcode 16 compatibility patch")


if __name__ == "__main__":
    main()
