# Release Checklist

## Before Tagging

- Confirm `swift test` passes locally.
- Confirm `EasyNet/README.md` matches the current public API and demo commands.
- Confirm `CHANGELOG.md` includes the target release entry.
- Confirm no unintended public API changes remain in work-in-progress state.
- Confirm demo binaries still run:
  - `swift run EasyNetTerminalServerDemo 9999`
  - `swift run EasyNetTerminalClientDemo 127.0.0.1 9999 --message hello`

## Suggested Current Release

- Recommended version: `0.1.0-beta.2`
- Alternative stable-style version: `0.1.0`
- Recommended tag choice: `0.1.0-beta.2`
  - because the SDK is now usable, documented, and API guidance has been tightened, but another round of real-world feedback is still valuable before a stable tag

## Release Notes Focus

- Layered architecture is in place: transport, protocol core, plugin, runtime, facade.
- Request pipeline supports timeout, retry, backoff, jitter, and typed response decoding.
- Server runtime has dedicated lifecycle, decoder-state, and inbound-pipeline components.
- Builder now snapshots plugin configuration at build time and supports plugin factories.
- Full package test suite currently passes.

## After Tagging

- Publish GitHub release notes from `RELEASE_NOTES_0.1.0-beta.2.md`.
- Keep `CHANGELOG.md` as the historical change log.
- Attach short usage pointers:
  - package dependency snippet
  - minimal client example
  - minimal server example
- Verify the README renders correctly on GitHub.
