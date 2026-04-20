import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class MockTransportClient: TransportClient, @unchecked Sendable {
    var state: ConnectionState = .idle
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var buffers: [ByteBuffer] = []
    private var startCount = 0

    init() {
        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func start() {
        state = .connecting
        lock.withLock {
            startCount += 1
        }
        continuation.yield(.connecting)
    }

    func stop() {
        state = .disconnected
        continuation.finish()
    }

    func send(_ buffer: ByteBuffer) async throws {
        lock.withLock {
            buffers.append(buffer)
        }
    }

    func emit(_ event: sending TransportEvent) {
        continuation.yield(event)
    }

    var sentBuffersCount: Int {
        lock.withLock {
            buffers.count
        }
    }

    var lastSentBuffer: ByteBuffer? {
        lock.withLock {
            buffers.last
        }
    }

    var startInvocations: Int {
        lock.withLock {
            startCount
        }
    }
}

final class FailingMockTransportClient: TransportClient, @unchecked Sendable {
    var state: ConnectionState = .idle
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var attemptsStorage = 0

    init() {
        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func start() {
        state = .connecting
        continuation.yield(.connecting)
    }

    func stop() {
        state = .disconnected
        continuation.finish()
    }

    func send(_ buffer: ByteBuffer) async throws {
        lock.withLock {
            attemptsStorage += 1
        }
        throw ConnectionCloseReason.transportError("mock_send_failed")
    }

    var sendAttempts: Int {
        lock.withLock {
            attemptsStorage
        }
    }
}

final class MockTransportServer: TransportServer, @unchecked Sendable {
    var state: ConnectionState = .idle
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var buffers: [ByteBuffer] = []
    private var connectionIDs: [ConnectionID] = []

    init() {
        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func start() async throws {
        state = .connecting
        continuation.yield(.connecting)
    }

    func stop() {
        state = .disconnected
        continuation.finish()
    }

    func send(_ buffer: ByteBuffer, to connectionID: ConnectionID) async throws {
        lock.withLock {
            buffers.append(buffer)
            connectionIDs.append(connectionID)
        }
    }

    func emit(_ event: sending TransportEvent) {
        continuation.yield(event)
    }

    var sentBuffersCount: Int {
        lock.withLock {
            buffers.count
        }
    }

    var lastConnectionID: ConnectionID? {
        lock.withLock {
            connectionIDs.last
        }
    }
}

struct TestOnlyMessage: DomainMessage {
    let value: String
}

final class TestOnlyPlugin: ProtocolPlugin, PacketMapper {
    let key = "test.only.plugin"
    private let command: UInt16

    init(command: UInt16) {
        self.command = command
    }

    func setup(in registry: PluginRegistry) {
        registry.register(mapper: self)
    }

    func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        guard packet.header.command == command else {
            return nil
        }
        return TestOnlyMessage(value: String(decoding: packet.payload, as: UTF8.self))
    }

    func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard let message = message as? TestOnlyMessage else {
            return nil
        }
        return ProtocolPacket(
            header: ProtocolHeader(magic: .request, command: command),
            payload: Array(message.value.utf8)
        )
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class MockPluginContext: PluginContext, @unchecked Sendable {
    var connectionContext: ConnectionContext? = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:9999", remoteAddress: "127.0.0.1:5000")

    private let lock = NSLock()
    private var sentPacketsStorage: [ProtocolPacket] = []
    private var sentMessagesStorage: [any DomainMessage] = []

    func send(packet: ProtocolPacket) async throws {
        lock.withLock {
            sentPacketsStorage.append(packet)
        }
    }

    func send(message: any DomainMessage) async throws {
        lock.withLock {
            sentMessagesStorage.append(message)
        }
    }

    func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await send(packet: packet)
    }

    func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await send(message: message)
    }

    var sentMessages: [any DomainMessage] {
        get async {
            lock.withLock {
                sentMessagesStorage
            }
        }
    }
}

func waitUntil(timeoutNanoseconds: UInt64, condition: @escaping @Sendable () async -> Bool) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func waitForSentBuffer(
    from transport: MockTransportClient,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async throws -> ByteBuffer {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if let buffer = transport.lastSentBuffer {
            return buffer
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    throw IntegrationTestError.commandTimedOut
}

func collectEvents(
    from iterator: inout AsyncStream<RuntimeEvent>.AsyncIterator,
    count: Int
) async -> [RuntimeEvent] {
    var events: [RuntimeEvent] = []

    while events.count < count, let event = await iterator.next() {
        events.append(event)
    }

    return events
}

func packageRootURL() throws -> URL {
    let fileURL = URL(fileURLWithPath: #filePath)
    let packageRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path) else {
        throw IntegrationTestError.packageRootNotFound
    }
    return packageRoot
}

func ensureBuiltProduct(named name: String, in packageRoot: URL) throws -> URL {
    if let existing = findBuiltProduct(named: name, in: packageRoot) {
        return existing
    }

    _ = try runCommand(
        executable: "/usr/bin/env",
        arguments: ["swift", "build", "--product", name],
        currentDirectoryURL: packageRoot,
        timeout: 120
    )

    if let built = findBuiltProduct(named: name, in: packageRoot) {
        return built
    }

    throw IntegrationTestError.productNotFound(name)
}

func findBuiltProduct(named name: String, in packageRoot: URL) -> URL? {
    let buildRoot = packageRoot.appendingPathComponent(".build")
    guard let enumerator = FileManager.default.enumerator(
        at: buildRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    for case let fileURL as URL in enumerator {
        guard fileURL.lastPathComponent == name else {
            continue
        }
        guard
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
            values.isRegularFile == true,
            values.isExecutable == true
        else {
            continue
        }
        return fileURL
    }

    return nil
}

@discardableResult
func runCommand(
    executable: String,
    arguments: [String],
    currentDirectoryURL: URL,
    timeout: TimeInterval
) throws -> CommandResult {
    let process = try RunningProcess(
        executableURL: URL(fileURLWithPath: executable),
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
    )
    defer { process.terminate() }

    guard let status = process.waitForExit(timeout: timeout) else {
        throw IntegrationTestError.commandTimedOut
    }
    let output = process.output
    guard status == 0 else {
        throw IntegrationTestError.commandFailed(output)
    }
    return CommandResult(output: output)
}

struct CommandResult {
    let output: String
}

final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let pipe: Pipe
    private let inputPipe: Pipe
    private let lock = NSLock()
    private var outputStorage = ""

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL) throws {
        self.process = Process()
        self.pipe = Pipe()
        self.inputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let string = String(decoding: data, as: UTF8.self)
            self.lock.withLock {
                self.outputStorage += string
            }
        }

        try process.run()
    }

    var output: String {
        lock.withLock {
            outputStorage
        }
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if output.contains(needle) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return output.contains(needle)
    }

    func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            return nil
        }
        return process.terminationStatus
    }

    func sendStdinLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        inputPipe.fileHandleForWriting.write(data)
    }

    func terminate() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            _ = waitForExit(timeout: 5)
        }
    }
}

enum IntegrationTestError: Error {
    case packageRootNotFound
    case commandTimedOut
    case commandFailed(String)
    case productNotFound(String)
}
