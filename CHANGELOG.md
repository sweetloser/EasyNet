# Changelog

All notable changes to this package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.0-beta.1 - 2026-04-17

### Added

- Added layered runtime components for request orchestration, server connection lifecycle, connection decoder state, and server inbound processing.
- Added packet-level and message-level request APIs with typed response decoding.
- Added request policy support for timeout, retry count, retry condition, retry backoff, and jitter.
- Added facade-level `EasyNetClient.start()` / `stop()` aliases and labeled `EasyNetServer.send(packet:to:)` / `send(message:to:)`.
- Added builder plugin factory support through `addPluginFactory(...)`.
- Added terminal client/server demos and expanded SDK documentation for GitHub publishing.

### Changed

- Unified protocol header semantics from `kind` to `magic`.
- Reduced runtime duplication by extracting outbound sender, event emitter, request orchestrator, server lifecycle coordinator, decoder store, and inbound pipeline.
- Changed builder behavior to snapshot plugin configuration at build time so already-built client/server instances are isolated from later builder mutations.
- Stabilized integration tests to reuse local build products instead of using network-sensitive scratch builds.

### Tested

- Verified with full `swift test` run: 24 tests passed, 0 failures.
