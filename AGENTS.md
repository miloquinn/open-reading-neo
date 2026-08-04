# Repository Working Rules

These rules are mandatory for every coding and release task in this repository.

## CI and release diagnosis

- Treat product builds, core regression tests, and stateful Flutter widget tests as separate signals.
- Never report a platform build as broken when the platform build job passed and only a test process failed.
- Flutter widget suites that own process-global state (SharedPreferences, platform channels, image codecs, static controllers, or singleton services) must run in isolated processes when combined execution can leak state or hang.
- Keep all meaningful assertions active. Fix or isolate flaky infrastructure; do not silently skip tests or label them as product failures.
- CI job and step names must identify the failing layer: `Product build`, `Core Flutter validation`, or `Stateful widget tests`.
- A known test-runner hang must not block a release after the actual release builds and targeted release regressions have passed. Record the test-infrastructure issue separately and continue the verified release path.
- Before changing application code for a CI failure, reproduce the failing test alone. If it passes alone and fails only in the combined suite, investigate test isolation first.

## Release procedure

- Verify the release tag points to the intended commit.
- Use the tag-triggered release workflow to build and publish assets; do not create an empty public Release first.
- Verify every platform artifact job independently before diagnosing the publish step.
- A publish/API failure after all artifact jobs succeed is a release-automation failure, not an application build failure. Retry or repair only the publish stage when possible.
- Preserve user-owned generated files and unrelated dirty-worktree changes.
- Report the public Release URL, workflow URL, artifact checksums, and any physical-device testing gap.

## Commit protocol

- Follow the workspace Lore commit format and include concrete `Tested:` and `Not-tested:` trailers.
