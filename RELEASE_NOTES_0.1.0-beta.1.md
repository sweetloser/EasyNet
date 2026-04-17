# EasyNet 0.1.0-beta.1

EasyNet 首个可发布预览版本。

这个版本重点完成了新版 SDK 的基础分层、请求编排能力、服务端运行时拆分，以及 GitHub 发布所需的文档和 demo 收口。

## Highlights

- Layered architecture across transport, protocol core, plugin, runtime, and facade.
- Packet-level and message-level request APIs with typed response decoding.
- Request policy support for timeout, retry, retry condition, backoff, and jitter.
- Server runtime now has dedicated lifecycle, decoder-store, and inbound-pipeline components.
- Builder snapshots plugin configuration at build time and supports plugin factories.
- Terminal client/server demos and package documentation are ready for external users.

## What Is Included

- `EasyNetTransport`
  - TCP client/server transport
  - connection state and byte stream events
- `EasyNetProtocolCore`
  - `ProtocolPacket`
  - `ProtocolHeader`
  - packet codec and payload serializers
- `EasyNetProtocolPlugin`
  - plugin registration
  - packet mapping
  - route handling
  - lifecycle hooks
- `EasyNetRuntime`
  - request orchestration
  - runtime event stream
  - retry / timeout / jitter policy
  - server lifecycle coordination
  - connection decoder store
  - server inbound pipeline
- `EasyNet`
  - `EasyNetBuilder`
  - `EasyNetClient`
  - `EasyNetServer`

## Public API Notes

- `ProtocolHeader.kind` has been unified to `ProtocolHeader.magic`
- `EasyNetClient` now supports:
  - `start()` / `stop()`
  - `connect()` / `disconnect()` as compatibility aliases
  - packet/message request APIs
  - typed response request APIs
- `EasyNetServer` now supports labeled send APIs:
  - `send(packet:to:)`
  - `send(message:to:)`
- `EasyNetBuilder` now supports:
  - plugin snapshot isolation at build time
  - `addPluginFactory(...)` for fresh plugin instances per build

## Verification

- Full `swift test` passes locally
- Current status:
  - 24 tests passed
  - 0 failures

## Suggested Positioning

- Recommended tag for this release: `0.1.0-beta.1`
- Recommended messaging:
  - usable preview release
  - suitable for early adopters
  - public API is stabilizing, but further refinement is expected before a long-term stable `1.0`

## Quick Start

Add the package in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/EasyNet.git", from: "0.1.0-beta.1")
]
```

Then depend on the product:

```swift
dependencies: [
    .product(name: "EasyNet", package: "EasyNet")
]
```

## Docs

- `README.md`
- `CHANGELOG.md`
- `RELEASE_CHECKLIST.md`
