# Changelog

All notable changes to this package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.0-beta.2 - 2026-04-20

### Added

- Added client auto reconnect with configurable backoff and jitter.
- Added client heartbeat scheduling and heartbeat failure reporting.
- Added client and server traffic monitoring with unified `RuntimeEvent.traffic` snapshots.
- Added client and server observability configuration entry points.
- Added facade typealiases such as `EasyNetRequestOptions` and `EasyNetClientObservabilityOptions` to reduce direct exposure of runtime naming in user code.
- Added `RuntimeEvent` convenience accessors for common event payload extraction.
- Added formal README guidance for defining custom business messages and plugins.
- Added a release readiness checklist document for beta publication flow.

### Changed

- Split the previous monolithic `EasyNetCoreTests.swift` into focused test files with shared `TestSupport`.
- Refined README to distinguish recommended APIs from compatibility aliases and system plugins from demo plugins.
- Standardized facade request guidance around `request(packet:...)` while keeping unlabeled packet request calls as compatibility aliases.
- Reduced public API surface by moving internal request orchestration types and runtime construction entry points out of the intended public path.
- Moved plugin command constants to package visibility and clarified plugin/message usage boundaries in documentation.

### Tested

- Verified with full `swift test` run: 37 tests passed, 0 failures.

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
