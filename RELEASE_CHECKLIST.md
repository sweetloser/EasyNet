# Release Checklist

## Before Tagging

- Confirm `swift test` passes locally.
- Confirm `EasyNet/README.md` matches the current public API and demo commands.
- Confirm `CHANGELOG.md` includes the target release entry.
- Confirm no unintended public API changes remain in work-in-progress state.
- Confirm demo binaries still run:
  - `swift run EasyNetTerminalServerDemo 9999`
  - `swift run EasyNetTerminalClientDemo 127.0.0.1 9999 --message hello`

## Suggested First Release

- Recommended version: `0.1.0-beta.1`
- Alternative stable-style version: `0.1.0`
- Recommended first public tag choice: `0.1.0-beta.1`
  - because the SDK is now usable and tested, but public API refinement is still likely in the next iterations

## Release Notes Focus

- Layered architecture is in place: transport, protocol core, plugin, runtime, facade.
- Request pipeline supports timeout, retry, backoff, jitter, and typed response decoding.
- Server runtime has dedicated lifecycle, decoder-state, and inbound-pipeline components.
- Builder now snapshots plugin configuration at build time and supports plugin factories.
- Full package test suite currently passes.

## After Tagging

- Publish GitHub release notes from `RELEASE_NOTES_0.1.0-beta.1.md`.
- Keep `CHANGELOG.md` as the historical change log.
- Attach short usage pointers:
  - package dependency snippet
  - minimal client example
  - minimal server example
- Verify the README renders correctly on GitHub.
