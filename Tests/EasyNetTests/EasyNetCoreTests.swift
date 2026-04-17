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
    func testRuntimeRetryBackoffExponentialDelayCalculation() {
        let backoff = RuntimeRetryBackoff.exponential(initialDelay: 0.1, multiplier: 2, maxDelay: nil)

        XCTAssertEqual(backoff.delay(forRetryAttempt: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 2), 0.2, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 3), 0.4, accuracy: 0.0001)
    }

    func testRuntimeRetryBackoffExponentialRespectsMaxDelay() {
        let backoff = RuntimeRetryBackoff.exponential(
            initialDelay: 0.1,
            multiplier: 3,
            maxDelay: 0.5
        )

        XCTAssertEqual(backoff.delay(forRetryAttempt: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 2), 0.3, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 4), 0.5, accuracy: 0.0001)
    }

    func testRuntimeRetryBackoffFixedJitterUsesExpectedRange() {
        let backoff = RuntimeRetryBackoff.fixed(1.0)
        let jitter = RuntimeRetryJitter.ratio(0.2)

        XCTAssertEqual(backoff.delay(forRetryAttempt: 1, jitter: jitter, sample: 0.0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 1, jitter: jitter, sample: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 1, jitter: jitter, sample: 1.0), 1.2, accuracy: 0.0001)
    }

    func testRuntimeRetryBackoffExponentialJitterStillRespectsMaxDelay() {
        let backoff = RuntimeRetryBackoff.exponential(
            initialDelay: 0.5,
            multiplier: 2,
            maxDelay: 1.0
        )
        let jitter = RuntimeRetryJitter.ratio(0.5)

        XCTAssertEqual(backoff.delay(forRetryAttempt: 2, jitter: jitter, sample: 1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(forRetryAttempt: 2, jitter: jitter, sample: 0.0), 0.5, accuracy: 0.0001)
    }

    func testRuntimeConnectionDecoderStoreReconnectCreatesNewDecoder() throws {
        let codec = EasyNetPacketCodec()
        let counter = LockedBox(0)
        let store = RuntimeConnectionDecoderStore {
            counter.withLock {
                $0 += 1
            }
            return codec.makeDecoder()
        }
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        let packet = ProtocolPacket(
            header: ProtocolHeader(magic: .request, command: 0x1001, session: 1),
            payload: [1, 2, 3]
        )

        store.connect(connection)
        XCTAssertEqual(counter.withLock { $0 }, 1)

        var firstBuffer = try codec.encode(packet)
        let firstPackets = try store.decode(&firstBuffer, from: connection)
        XCTAssertEqual(firstPackets.count, 1)
        XCTAssertEqual(counter.withLock { $0 }, 1)

        store.disconnect(connection)

        var secondBuffer = try codec.encode(packet)
        let secondPackets = try store.decode(&secondBuffer, from: connection)
        XCTAssertEqual(secondPackets.count, 1)
        XCTAssertEqual(counter.withLock { $0 }, 2)
    }

    func testRuntimeServerConnectionLifecycleCoordinatorHandlesListenerAndPeerConnections() async throws {
        let stream = AsyncStream<RuntimeEvent>.makeStream()
        let emitter = RuntimeEventEmitter(continuation: stream.continuation)
        var iterator = stream.stream.makeAsyncIterator()
        let decoderCounter = LockedBox(0)
        let connectedCounter = LockedBox(0)
        let disconnectedCounter = LockedBox(0)
        let decoderStore = RuntimeConnectionDecoderStore {
            decoderCounter.withLock { $0 += 1 }
            return EasyNetPacketCodec().makeDecoder()
        }
        let coordinator = RuntimeServerConnectionLifecycleCoordinator(
            decoderStore: decoderStore,
            emitter: emitter,
            makeContext: { connectionContext in
                let context = MockPluginContext()
                context.connectionContext = connectionContext
                return context
            },
            notifyConnected: { _ in
                connectedCounter.withLock { $0 += 1 }
            },
            notifyDisconnected: { _, _ in
                disconnectedCounter.withLock { $0 += 1 }
            }
        )

        let listenerContext = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:9999", remoteAddress: nil)
        let peerContext = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:9999", remoteAddress: "127.0.0.1:5000")

        await coordinator.handleConnected(listenerContext)
        let listenerEvents = await collectEvents(from: &iterator, count: 2)
        XCTAssertEqual(listenerEvents.count, 2)
        XCTAssertEqual(decoderCounter.withLock { $0 }, 0)
        XCTAssertEqual(connectedCounter.withLock { $0 }, 0)

        await coordinator.handleConnected(peerContext)
        let peerEvents = await collectEvents(from: &iterator, count: 1)
        XCTAssertEqual(peerEvents.count, 1)
        XCTAssertEqual(decoderCounter.withLock { $0 }, 1)
        XCTAssertEqual(connectedCounter.withLock { $0 }, 1)

        await coordinator.handleDisconnected(peerContext, reason: .remoteClosed)
        _ = await collectEvents(from: &iterator, count: 1)
        XCTAssertEqual(disconnectedCounter.withLock { $0 }, 1)
    }

    func testRuntimeServerInboundPipelineDecodesDispatchesAndResponds() async throws {
        let stream = AsyncStream<RuntimeEvent>.makeStream()
        let emitter = RuntimeEventEmitter(continuation: stream.continuation)
        var iterator = stream.stream.makeAsyncIterator()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let dispatcher = emitter.makePacketDispatcher(registry: registry)
        let decoderStore = RuntimeConnectionDecoderStore {
            EasyNetPacketCodec().makeDecoder()
        }
        let context = MockPluginContext()
        let pipeline = RuntimeServerInboundPipeline(
            decoderStore: decoderStore,
            dispatcher: dispatcher,
            makeContext: { _ in context }
        )
        let codec = EasyNetPacketCodec()
        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:9999", remoteAddress: "127.0.0.1:5000")
        let packet = try registry.encode(
            TerminalTextMessage(text: "server-pipeline", magic: .request, session: 42)
        )

        decoderStore.connect(connection)
        var buffer = try codec.encode(packet)
        try await pipeline.process(&buffer, from: connection)

        let events = await collectEvents(from: &iterator, count: 2)
        XCTAssertEqual(events.count, 2)

        let sentMessages = await context.sentMessages
        XCTAssertEqual(sentMessages.count, 1)
        let response = try XCTUnwrap(sentMessages.first as? TerminalTextMessage)
        XCTAssertEqual(response.text, "echo: server-pipeline")
        XCTAssertEqual(response.magic, .response)
        XCTAssertEqual(response.session, 42)
    }

    func testEasyNetClientStartStopAliasesControlTransport() {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)

        client.start()
        XCTAssertEqual(transport.state, .connecting)

        client.stop()
        XCTAssertEqual(transport.state, .disconnected)
    }

    func testEasyNetServerLabeledSendDelegatesToRuntime() async throws {
        let transport = MockTransportServer()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let runtime = EasyNetRuntimeServer(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: registry
        )
        let server = EasyNetServer(runtime: runtime)
        let connectionID = ConnectionID()

        let packet = ProtocolPacket(
            header: ProtocolHeader(magic: .event, command: 0x2001, session: 7),
            payload: [9, 8, 7]
        )
        try await server.send(packet: packet, to: connectionID)
        try await server.send(
            message: TerminalTextMessage(text: "server-send", magic: .event, session: 8),
            to: connectionID
        )

        XCTAssertEqual(transport.sentBuffersCount, 2)
        XCTAssertEqual(transport.lastConnectionID, connectionID)
    }

    func testBuilderBuildSnapshotsRegistryAtBuildTime() async throws {
        let builder = EasyNetBuilder()
            .useTCPClient(host: "127.0.0.1", port: 9999)
            .addPlugin(TerminalTextPlugin())

        let client = try builder.buildClient()
        _ = builder.addPlugin(TestOnlyPlugin(command: 0x7777))

        do {
            try await client.send(message: TestOnlyMessage(value: "late-plugin"))
            XCTFail("Expected missing mapper")
        } catch {
            guard case PluginRegistryError.missingMapper = error else {
                XCTFail("Expected missing mapper, got \(error)")
                return
            }
        }
    }

    func testBuilderPluginFactoryCreatesFreshPluginPerBuild() throws {
        let counter = LockedBox(0)
        let builder = EasyNetBuilder()
            .useTCPClient(host: "127.0.0.1", port: 9999)
            .addPluginFactory {
                counter.withLock { $0 += 1 }
                return TestOnlyPlugin(command: 0x8888)
            }

        _ = try builder.buildClient()
        _ = try builder.buildClient()

        XCTAssertEqual(counter.withLock { $0 }, 2)
    }

    func testPacketCodecRoundTrip() throws {
        let codec = EasyNetPacketCodec()
        let header = ProtocolHeader(
            magic: .request,
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
        XCTAssertEqual(packets[0].header.magic, packet.header.magic)
        XCTAssertEqual(packets[0].payload, packet.payload)
    }

    func testTerminalTextPluginEncodeAndDecode() throws {
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())

        let message = TerminalTextMessage(text: "hello", magic: .request, session: 3)
        let packet = try registry.encode(message)
        let decoded = try registry.decode(packet) as? TerminalTextMessage

        XCTAssertEqual(packet.header.command, TerminalDemoCommand.textMessage)
        XCTAssertEqual(packet.header.magic, .request)
        XCTAssertEqual(packet.header.session, 3)
        XCTAssertEqual(decoded?.text, "hello")
        XCTAssertEqual(decoded?.magic, .request)
        XCTAssertEqual(decoded?.session, 3)
    }

    func testTerminalTextPluginHandlesRequestWithEchoResponse() async throws {
        let plugin = TerminalTextPlugin()
        let context = MockPluginContext()
        let packet = try XCTUnwrap(
            try plugin.encode(TerminalTextMessage(text: "ping", magic: .request, session: 11))
        )

        try await plugin.handle(packet, context: context)

        let sentMessages = await context.sentMessages
        XCTAssertEqual(sentMessages.count, 1)
        let response = try XCTUnwrap(sentMessages.first as? TerminalTextMessage)
        XCTAssertEqual(response.magic, .response)
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

        let requestPacket = try registry.encode(TerminalTextMessage(text: "runtime", magic: .request, session: 21))
        let responsePacket = try registry.encode(TerminalTextMessage(text: "echo: runtime", magic: .response, session: 21))

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
        XCTAssertEqual(result.header.magic, .response)

        runtime.stop()
    }

    func testRuntimeClientRequestMessageReturnsTypedResponse() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestMessage = TerminalTextMessage(text: "typed", magic: .request, session: 31)
        let responsePacket = try registry.encode(
            TerminalTextMessage(text: "echo: typed", magic: .response, session: 31)
        )

        let task = Task {
            try await runtime.request(message: requestMessage, as: TerminalTextMessage.self)
        }

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            transport.sentBuffersCount > 0
        }

        let responseBuffer = try codec.encode(responsePacket)
        transport.emit(.inboundBytes(connection, responseBuffer))

        let response = try await task.value
        XCTAssertEqual(response.magic, .response)
        XCTAssertEqual(response.session, 31)
        XCTAssertEqual(response.text, "echo: typed")

        runtime.stop()
    }

    func testRuntimeClientRequestAutoAssignsSessionWhenMissing() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestMessage = TerminalTextMessage(text: "auto-session", magic: .request)
        let task = Task {
            try await runtime.request(message: requestMessage, as: TerminalTextMessage.self)
        }

        let outboundBuffer = try await waitForSentBuffer(from: transport)
        var sentBuffer = outboundBuffer
        var decoder = codec.makeDecoder()
        let sentPackets = try decoder.decode(&sentBuffer)
        let sentPacket = try XCTUnwrap(sentPackets.first)

        XCTAssertEqual(sentPacket.header.magic, .request)
        XCTAssertNotEqual(sentPacket.header.session, 0)

        let responsePacket = try registry.encode(
            TerminalTextMessage(text: "echo: auto-session", magic: .response, session: sentPacket.header.session)
        )
        let responseBuffer = try codec.encode(responsePacket)
        transport.emit(.inboundBytes(connection, responseBuffer))

        let response = try await task.value
        XCTAssertEqual(response.session, sentPacket.header.session)
        XCTAssertEqual(response.text, "echo: auto-session")

        runtime.stop()
    }

    func testRuntimeClientRequestTimesOut() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        do {
            _ = try await runtime.request(
                message: TerminalTextMessage(text: "timeout", magic: .request),
                as: TerminalTextMessage.self,
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch let error as RuntimeRequestError {
            switch error {
            case .timeout(let session):
                XCTAssertNotEqual(session, 0)
            default:
                XCTFail("Expected timeout error, got \(error)")
            }
        }

        runtime.stop()
    }

    func testRuntimeClientRequestRetriesAfterTimeout() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestMessage = TerminalTextMessage(text: "retry", magic: .request)
        let task = Task {
            try await runtime.request(
                message: requestMessage,
                as: TerminalTextMessage.self,
                options: RuntimeRequestOptions(timeout: 0.03, retryCount: 1, retryDelay: 0.01)
            )
        }

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            transport.sentBuffersCount >= 2
        }

        XCTAssertEqual(transport.sentBuffersCount, 2)

        let outboundBuffer = try await waitForSentBuffer(from: transport)
        var sentBuffer = outboundBuffer
        var decoder = codec.makeDecoder()
        let sentPackets = try decoder.decode(&sentBuffer)
        let sentPacket = try XCTUnwrap(sentPackets.first)

        let responsePacket = try registry.encode(
            TerminalTextMessage(text: "echo: retry", magic: .response, session: sentPacket.header.session)
        )
        let responseBuffer = try codec.encode(responsePacket)
        transport.emit(.inboundBytes(connection, responseBuffer))

        let response = try await task.value
        XCTAssertEqual(response.text, "echo: retry")
        XCTAssertEqual(response.magic, .response)

        runtime.stop()
    }

    func testRuntimeClientRequestRetriesTimeoutOnlyPolicy() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let options: RuntimeRequestOptions = .init(
            timeout: 0.03,
            retryCount: 1,
            retryCondition: .timeoutOnly,
            retryBackoff: .fixed(0.01)
        )
        let task = Task {
            try await runtime.request(
                message: TerminalTextMessage(text: "timeout-retry", magic: .request),
                as: TerminalTextMessage.self,
                options: options
            )
        }

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            transport.sentBuffersCount >= 2
        }

        XCTAssertEqual(transport.sentBuffersCount, 2)

        let outboundBuffer = try await waitForSentBuffer(from: transport)
        var sentBuffer = outboundBuffer
        var decoder = codec.makeDecoder()
        let sentPackets = try decoder.decode(&sentBuffer)
        let sentPacket = try XCTUnwrap(sentPackets.first)

        let responsePacket = try registry.encode(
            TerminalTextMessage(text: "echo: timeout-retry", magic: .response, session: sentPacket.header.session)
        )
        let responseBuffer = try codec.encode(responsePacket)
        transport.emit(.inboundBytes(connection, responseBuffer))

        let response = try await task.value
        XCTAssertEqual(response.text, "echo: timeout-retry")
        runtime.stop()
    }

    func testRuntimeClientRequestDoesNotRetrySendFailureWhenTimeoutOnlyPolicy() async throws {
        let transport = FailingMockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)

        runtime.start()

        let options: RuntimeRequestOptions = .init(
            timeout: 0.03,
            retryCount: 2,
            retryCondition: .timeoutOnly,
            retryBackoff: .fixed(0.01)
        )
        do {
            _ = try await runtime.request(
                message: TerminalTextMessage(text: "send-fail", magic: .request),
                as: TerminalTextMessage.self,
                options: options
            )
            XCTFail("Expected transport failure")
        } catch let error as ConnectionCloseReason {
            switch error {
            case .transportError(let reason):
                XCTAssertEqual(reason, "mock_send_failed")
            default:
                XCTFail("Expected transport error, got \(error)")
            }
        }

        XCTAssertEqual(transport.sendAttempts, 1)
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
        let serverURL = try ensureBuiltProduct(
            named: "EasyNetTerminalServerDemo",
            in: packageRoot
        )
        let clientURL = try ensureBuiltProduct(
            named: "EasyNetTerminalClientDemo",
            in: packageRoot
        )

        let port = 24000 + Int.random(in: 0...999)

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
        let serverURL = try ensureBuiltProduct(
            named: "EasyNetTerminalServerDemo",
            in: packageRoot
        )
        let clientURL = try ensureBuiltProduct(
            named: "EasyNetTerminalClientDemo",
            in: packageRoot
        )

        let port = 25000 + Int.random(in: 0...999)

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

    var lastSentBuffer: ByteBuffer? {
        lock.withLock {
            buffers.last
        }
    }
}

private final class FailingMockTransportClient: TransportClient, @unchecked Sendable {
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

private final class MockTransportServer: TransportServer, @unchecked Sendable {
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

private struct TestOnlyMessage: DomainMessage {
    let value: String
}

private final class TestOnlyPlugin: ProtocolPlugin, PacketMapper {
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

private final class LockedBox<Value>: @unchecked Sendable {
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

private func waitForSentBuffer(
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

private func collectEvents(
    from iterator: inout AsyncStream<RuntimeEvent>.AsyncIterator,
    count: Int
) async -> [RuntimeEvent] {
    var events: [RuntimeEvent] = []

    while events.count < count, let event = await iterator.next() {
        events.append(event)
    }

    return events
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

private func ensureBuiltProduct(named name: String, in packageRoot: URL) throws -> URL {
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

private func findBuiltProduct(named name: String, in packageRoot: URL) -> URL? {
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
    case productNotFound(String)
}
