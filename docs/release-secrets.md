# Release secrets and variables

This repository may be public. Never commit a secret value, certificate,
private key, provisioning profile, keystore, token, or production host detail.

Release credentials belong to the protected GitHub `release` Environment.
External pull requests do not receive these values. Release jobs must only run
from a maintainer-created version tag or an explicitly approved manual run.

## GitHub Environment secrets

| Name | Purpose |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded Android release keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Android keystore password |
| `ANDROID_KEY_ALIAS` | Android signing alias |
| `ANDROID_KEY_PASSWORD` | Android signing-key password |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password for the Developer ID PKCS#12 file |
| `MACOS_NOTARY_KEY_ID` | App Store Connect API key ID used by `notarytool` |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `MACOS_NOTARY_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect `.p8` private key |
| `MACOS_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID profile for `com.niki.xxread` |
| `PUBLIC_RELEASE_TOKEN` | Fine-grained token that can publish to `miloquinn/open-reading` |
| `OFFICIAL_SITE_SSH_HOST` | Official-site deployment host |
| `OFFICIAL_SITE_SSH_PORT` | Official-site SSH port |
| `OFFICIAL_SITE_SSH_USER` | Restricted official-site release account |
| `OFFICIAL_SITE_SSH_PRIVATE_KEY` | Private key for the restricted release account |
| `OFFICIAL_SITE_SSH_KNOWN_HOSTS` | Pinned SSH host-key entry |

The release workflow embeds the Developer ID profile and verifies that it
matches both `com.niki.xxread` and the imported Developer ID certificate.
Apple does not grant native Sign in with Apple to Developer ID distribution;
the website-distributed macOS app therefore uses the web/device authorization
flow, while iOS keeps the native system authorization sheet.

## GitHub Environment variables

| Name | Purpose |
| --- | --- |
| `MACOS_RELEASE_ENABLED` | Enables signed and notarized macOS artifacts when set to `true` |
| `IOS_TESTFLIGHT_URL` | Optional public TestFlight URL added to release notes |

## Local private inventory

Maintain `.secrets/local-release-inventory.md` locally. The `.secrets/`
directory is ignored by Git. Store only credential metadata there—never the
secret values themselves. Actual values should remain in GitHub Secrets,
Keychain, or a password manager.

Before making the repository public:

1. Scan the tracked tree and complete Git history for leaked credentials.
2. Verify the `release` Environment has deployment-branch/tag protection and
   required reviewers where the GitHub plan supports them.
3. Confirm pull-request workflows use read-only permissions and never use
   `pull_request_target` with untrusted code.
4. Rotate any credential that has ever been copied into a tracked file, build
   log, issue, or pull request.
