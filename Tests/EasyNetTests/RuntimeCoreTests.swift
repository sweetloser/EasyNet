import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class RuntimeCoreTests: XCTestCase {
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

    func testRuntimeEventAccessorsExposeCommonFields() {
        let context = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        let packet = ProtocolPacket(
            header: ProtocolHeader(magic: .request, command: 0x1234, session: 7),
            payload: [1, 2]
        )
        let traffic = RuntimeTrafficStats(
            readKBps: 1.5,
            writeKBps: 2.5,
            totalReadKB: 3.5,
            totalWriteKB: 4.5
        )
        let message = TerminalTextMessage(text: "hello", magic: .event, session: 9)

        let stateEvent = RuntimeEvent.stateChanged(.connected)
        XCTAssertEqual(stateEvent.connectionState, .connected)
        XCTAssertNil(stateEvent.connectionContext)
        XCTAssertFalse(stateEvent.isObservabilityEvent)

        let connectedEvent = RuntimeEvent.connected(context)
        XCTAssertEqual(connectedEvent.connectionContext?.id, context.id)

        let packetEvent = RuntimeEvent.packet(context, packet)
        XCTAssertEqual(packetEvent.connectionContext?.id, context.id)
        XCTAssertEqual(packetEvent.packetValue?.header.command, 0x1234)

        let messageEvent = RuntimeEvent.message(context, message)
        let extractedMessage = messageEvent.messageValue as? TerminalTextMessage
        XCTAssertEqual(extractedMessage?.text, "hello")

        let trafficEvent = RuntimeEvent.traffic(context, traffic)
        XCTAssertEqual(trafficEvent.trafficStats, traffic)
        XCTAssertTrue(trafficEvent.isObservabilityEvent)

        let disconnectedEvent = RuntimeEvent.disconnected(context, .remoteClosed)
        XCTAssertEqual(disconnectedEvent.connectionContext?.id, context.id)
        XCTAssertTrue(disconnectedEvent.error is ConnectionCloseReason)
        XCTAssertTrue(disconnectedEvent.isObservabilityEvent)

        let failureEvent = RuntimeEvent.failure(RuntimeHeartbeatError.lostResponses(count: 2))
        XCTAssertTrue(failureEvent.error is RuntimeHeartbeatError)
        XCTAssertTrue(failureEvent.isObservabilityEvent)
    }
}
