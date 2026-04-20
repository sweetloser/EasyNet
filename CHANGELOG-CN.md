# 更新日志

本文件记录该包的所有重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)。

## Unreleased

### 新增

- 暂无。

### 变更

- 暂无。

### 测试

- 暂未执行。

## 0.1.0-beta.2 - 2026-04-20

### 新增

- 新增客户端自动重连，支持可配置退避与抖动。
- 新增客户端心跳调度与心跳失败上报。
- 新增客户端与服务端流量监控，并统一为 `RuntimeEvent.traffic` 快照事件。
- 新增客户端与服务端可观测性配置入口。
- 新增 `EasyNetRequestOptions`、`EasyNetClientObservabilityOptions` 等 facade 层类型别名，减少业务代码直接暴露 runtime 命名。
- 新增 `RuntimeEvent` 常用访问器，便于提取事件负载。
- 在 README 中新增正式的业务消息与插件定义指引。
- 新增 beta 发布流程使用的发布检查清单文档。

### 变更

- 将原本单体的 `EasyNetCoreTests.swift` 拆分为多个聚焦职责的测试文件，并提取共享 `TestSupport`。
- 调整 README，明确推荐 API 与兼容别名的边界，并区分系统插件与示例插件。
- 统一 facade 层请求示例为 `request(packet:...)`，同时保留无标签 packet 请求调用作为兼容别名。
- 通过收口内部请求编排类型与 runtime 构造入口，缩小公共 API 暴露面。
- 将插件命令常量调整为 package 可见，并进一步澄清插件与消息的使用边界。

### 测试

- 已完整执行 `swift test`：37 个测试全部通过，0 失败。

## 0.1.0-beta.1 - 2026-04-17

### 新增

- 新增分层 runtime 组件，覆盖请求编排、服务端连接生命周期、连接解码状态与服务端入站处理。
- 新增 packet 级与 message 级请求 API，支持类型化响应解码。
- 新增请求策略能力，支持超时、重试次数、重试条件、退避与抖动。
- 新增 facade 层 `EasyNetClient.start()` / `stop()` 别名，以及带标签的 `EasyNetServer.send(packet:to:)` / `send(message:to:)`。
- 通过 `addPluginFactory(...)` 新增 builder 插件工厂支持。
- 新增终端 client/server demo，并补充 GitHub 发布相关 SDK 文档。

### 变更

- 统一协议头语义，将 `kind` 调整为 `magic`。
- 通过抽取 outbound sender、event emitter、request orchestrator、server lifecycle coordinator、decoder store 与 inbound pipeline，减少 runtime 重复实现。
- 调整 builder 行为为构建时快照插件配置，确保已构建的 client/server 实例不受后续 builder 变更影响。
- 稳定化集成测试，复用本地构建产物，避免依赖易受网络影响的临时构建。

### 测试

- 已完整执行 `swift test`：24 个测试全部通过，0 失败。
