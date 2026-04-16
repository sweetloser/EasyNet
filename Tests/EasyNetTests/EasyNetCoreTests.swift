import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class EasyNetCoreTests: XCTestCase {
    func testPacketCodecRoundTrip() throws {
        let codec = EasyNetPacketCodec()
        let header = ProtocolHeader(
            kind: .request,
            version: 1,
            codec: .json,
            command: 0x1001,
            session: 7,
            flags: 1,
            sequence: 9,
            status: 0,
            checksum: 123
        )
        let packet = ProtocolPacket(header: header, payload: [1, 2, 3, 4])

        var buffer = try codec.encode(packet)
        var decoder = codec.makeDecoder()
        let packets = try decoder.decode(&buffer)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].header.command, packet.header.command)
        XCTAssertEqual(packets[0].header.session, packet.header.session)
        XCTAssertEqual(packets[0].header.kind, packet.header.kind)
        XCTAssertEqual(packets[0].payload, packet.payload)
    }

    func testTerminalTextPluginEncodeAndDecode() throws {
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())

        let message = TerminalTextMessage(text: "hello", kind: .request, session: 3)
        let packet = try registry.encode(message)
        let decoded = try registry.decode(packet) as? TerminalTextMessage

        XCTAssertEqual(packet.header.command, TerminalDemoCommand.textMessage)
        XCTAssertEqual(packet.header.kind, .request)
        XCTAssertEqual(packet.header.session, 3)
        XCTAssertEqual(decoded?.text, "hello")
        XCTAssertEqual(decoded?.kind, .request)
        XCTAssertEqual(decoded?.session, 3)
    }

    func testTerminalTextPluginHandlesRequestWithEchoResponse() async throws {
        let plugin = TerminalTextPlugin()
        let context = MockPluginContext()
        let packet = try XCTUnwrap(
            try plugin.encode(TerminalTextMessage(text: "ping", kind: .request, session: 11))
        )

        try await plugin.handle(packet, context: context)

        let sentMessages = await context.sentMessages
        XCTAssertEqual(sentMessages.count, 1)
        let response = try XCTUnwrap(sentMessages.first as? TerminalTextMessage)
        XCTAssertEqual(response.kind, .response)
        XCTAssertEqual(response.session, 11)
        XCTAssertEqual(response.text, "echo: ping")
    }

    func testRuntimeClientRequestReceivesResponseThroughTransport() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestPacket = try registry.encode(TerminalTextMessage(text: "runtime", kind: .request, session: 21))
        let responsePacket = try registry.encode(TerminalTextMessage(text: "echo: runtime", kind: .response, session: 21))

        let task = Task {
            try await runtime.request(requestPacket)
        }

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            transport.sentBuffersCount > 0
        }

        let responseBuffer = try codec.encode(responsePacket)
        transport.emit(.inboundBytes(connection, responseBuffer))

        let result = try await task.value
        XCTAssertEqual(result.header.session, 21)
        XCTAssertEqual(result.header.kind, .response)

        runtime.stop()
    }

    func testBuilderRequiresExplicitClientConfiguration() {
        let builder = EasyNetBuilder().addPlugin(TerminalTextPlugin())

        XCTAssertThrowsError(try builder.buildClient()) { error in
            XCTAssertEqual(error as? EasyNetBuilderError, .missingClientConfiguration)
        }
    }

    func testTerminalProductsBuildAndCommunicate() throws {
        let packageRoot = try packageRootURL()
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyNetIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchPath) }

        _ = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--scratch-path", scratchPath.path, "--product", "EasyNetTerminalServerDemo"],
            currentDirectoryURL: packageRoot,
            timeout: 120
        )
        _ = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--scratch-path", scratchPath.path, "--product", "EasyNetTerminalClientDemo"],
            currentDirectoryURL: packageRoot,
            timeout: 120
        )

        let port = 24000 + Int.random(in: 0...999)
        let serverURL = scratchPath.appendingPathComponent("debug/EasyNetTerminalServerDemo")
        let clientURL = scratchPath.appendingPathComponent("debug/EasyNetTerminalClientDemo")

        let server = try RunningProcess(
            executableURL: serverURL,
            arguments: ["\(port)"],
            currentDirectoryURL: packageRoot
        )
        defer { server.terminate() }

        XCTAssertTrue(
            server.waitForOutput(containing: "[server] listening on", timeout: 10),
            "Server did not start listening in time. Output:\n\(server.output)"
        )

        let clientResult = try runCommand(
            executable: clientURL.path,
            arguments: ["127.0.0.1", "\(port)", "--message", "integration-ping", "--timeout", "5"],
            currentDirectoryURL: packageRoot,
            timeout: 20
        )

        XCTAssertTrue(
            clientResult.output.contains("[client] received: echo: integration-ping"),
            "Client did not receive echo response. Output:\n\(clientResult.output)"
        )
        XCTAssertTrue(
            clientResult.output.contains("[client] auto response confirmed: echo: integration-ping"),
            "Client auto mode did not confirm response. Output:\n\(clientResult.output)"
        )
        XCTAssertTrue(
            server.waitForOutput(containing: "integration-ping", timeout: 5),
            "Server did not log received message. Output:\n\(server.output)"
        )
    }

    func testInteractiveClientDoesNotLagPreviousResponse() throws {
        let packageRoot = try packageRootURL()
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyNetInteractive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchPath) }

        _ = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--scratch-path", scratchPath.path, "--product", "EasyNetTerminalServerDemo"],
            currentDirectoryURL: packageRoot,
            timeout: 120
        )
        _ = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--scratch-path", scratchPath.path, "--product", "EasyNetTerminalClientDemo"],
            currentDirectoryURL: packageRoot,
            timeout: 120
        )

        let port = 25000 + Int.random(in: 0...999)
        let serverURL = scratchPath.appendingPathComponent("debug/EasyNetTerminalServerDemo")
        let clientURL = scratchPath.appendingPathComponent("debug/EasyNetTerminalClientDemo")

        let server = try RunningProcess(
            executableURL: serverURL,
            arguments: ["\(port)"],
            currentDirectoryURL: packageRoot
        )
        defer { server.terminate() }

        XCTAssertTrue(
            server.waitForOutput(containing: "[server] listening on", timeout: 10),
            "Server did not start listening in time. Output:\n\(server.output)"
        )

        let client = try RunningProcess(
            executableURL: clientURL,
            arguments: ["127.0.0.1", "\(port)"],
            currentDirectoryURL: packageRoot
        )
        defer { client.terminate() }

        XCTAssertTrue(
            client.waitForOutput(containing: "Type text and press Enter", timeout: 10),
            "Client did not enter interactive mode in time. Output:\n\(client.output)"
        )

        client.sendStdinLine("first")
        XCTAssertTrue(
            client.waitForOutput(containing: "[client] received: echo: first", timeout: 5),
            "Client did not immediately receive first response. Output:\n\(client.output)"
        )

        client.sendStdinLine("second")
        XCTAssertTrue(
            client.waitForOutput(containing: "[client] received: echo: second", timeout: 5),
            "Client did not immediately receive second response. Output:\n\(client.output)"
        )

        client.sendStdinLine("/quit")
    }
}

private final class MockTransportClient: TransportClient, @unchecked Sendable {
    var state: ConnectionState = .idle
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var buffers: [ByteBuffer] = []

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
}

private final class MockPluginContext: PluginContext, @unchecked Sendable {
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

private func waitUntil(timeoutNanoseconds: UInt64, condition: @escaping @Sendable () async -> Bool) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func packageRootURL() throws -> URL {
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

@discardableResult
private func runCommand(
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

private struct CommandResult {
    let output: String
}

private final class RunningProcess: @unchecked Sendable {
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

private enum IntegrationTestError: Error {
    case packageRootNotFound
    case commandTimedOut
    case commandFailed(String)
}
