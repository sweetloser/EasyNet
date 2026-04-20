import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class ClientObservabilityTests: XCTestCase {
    func testEasyNetClientAutoReconnectRestartsAfterRemoteClose() async throws {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )

        client.enableAutoReconnect(
            RuntimeReconnectOptions(
                maxAttempts: 1,
                backoff: .fixed(0.01)
            )
        )

        client.start()
        transport.emit(.connected(connection))
        transport.emit(.disconnected(connection, .remoteClosed))

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            transport.startInvocations >= 2
        }

        XCTAssertEqual(transport.startInvocations, 2)
        client.disableAutoReconnect()
        client.stop()
    }

    func testEasyNetClientAutoReconnectIgnoresLocalDisconnect() async throws {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )

        client.enableAutoReconnect(
            RuntimeReconnectOptions(
                maxAttempts: 1,
                backoff: .fixed(0.01)
            )
        )

        client.start()
        transport.emit(.connected(connection))
        transport.emit(.disconnected(connection, .localClosed))

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.startInvocations, 1)

        client.disableAutoReconnect()
        client.stop()
    }

    func testEasyNetClientHeartbeatSendsHeartbeatRequest() async throws {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        let codec = EasyNetPacketCodec()

        client.enableHeartbeat(
            RuntimeHeartbeatOptions(
                interval: 0.01,
                timeout: 0.05,
                maxConsecutiveFailures: 2
            )
        )
        client.start()
        transport.emit(.connected(connection))

        let outboundBuffer = try await waitForSentBuffer(from: transport)
        var buffer = outboundBuffer
        var decoder = codec.makeDecoder()
        let packets = try decoder.decode(&buffer)
        let packet = try XCTUnwrap(packets.first)

        XCTAssertEqual(packet.header.command, SystemCommand.heartbeat)
        XCTAssertEqual(packet.header.magic, .request)

        client.disableHeartbeat()
        client.stop()
    }

    func testEasyNetClientHeartbeatEmitsFailureAfterThreshold() async throws {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        var iterator = client.events.makeAsyncIterator()

        client.enableHeartbeat(
            RuntimeHeartbeatOptions(
                interval: 0.01,
                timeout: 0.01,
                maxConsecutiveFailures: 1
            )
        )
        client.start()
        transport.emit(.connected(connection))

        try? await Task.sleep(nanoseconds: 100_000_000)
        var heartbeatError: RuntimeHeartbeatError?
        for _ in 0..<4 {
            guard let event = await iterator.next() else {
                break
            }
            if case .failure(let error as RuntimeHeartbeatError) = event {
                heartbeatError = error
                break
            }
        }

        switch try XCTUnwrap(heartbeatError) {
        case .lostResponses(let count):
            XCTAssertEqual(count, 1)
        }

        client.disableHeartbeat()
        client.stop()
    }

    func testEasyNetClientTrafficMonitorEmitsTrafficStats() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: codec,
            registry: registry
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        var iterator = client.events.makeAsyncIterator()

        client.enableTrafficMonitor(RuntimeTrafficMonitorOptions(interval: 0.01))
        client.start()
        transport.emit(.connected(connection))

        try await client.send(
            message: TerminalTextMessage(text: "traffic", magic: .request, session: 9)
        )

        let inboundPacket = try registry.encode(
            TerminalTextMessage(text: "echo: traffic", magic: .response, session: 9)
        )
        let inboundBuffer = try codec.encode(inboundPacket)
        transport.emit(.inboundBytes(connection, inboundBuffer))

        try? await Task.sleep(nanoseconds: 100_000_000)

        var stats: RuntimeTrafficStats?
        for _ in 0..<6 {
            guard let event = await iterator.next() else {
                break
            }
            if case .traffic(_, let trafficStats) = event {
                stats = trafficStats
                break
            }
        }

        let trafficStats = try XCTUnwrap(stats)
        XCTAssertGreaterThan(trafficStats.totalReadKB, 0)
        XCTAssertGreaterThan(trafficStats.totalWriteKB, 0)

        client.disableTrafficMonitor()
        client.stop()
    }

    func testEasyNetClientConfigureObservabilityEnablesTrafficAndHeartbeat() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: codec,
            registry: registry
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        var iterator = client.events.makeAsyncIterator()

        client.configureObservability(
            RuntimeClientObservabilityOptions(
                heartbeat: RuntimeHeartbeatOptions(interval: 0.01, timeout: 0.05, maxConsecutiveFailures: 3),
                trafficMonitor: RuntimeTrafficMonitorOptions(interval: 0.01)
            )
        )
        client.start()
        transport.emit(.connected(connection))

        let inboundPacket = try registry.encode(
            TerminalTextMessage(text: "echo: hb", magic: .response, session: 1)
        )
        let inboundBuffer = try codec.encode(inboundPacket)
        transport.emit(.inboundBytes(connection, inboundBuffer))

        try? await Task.sleep(nanoseconds: 100_000_000)

        var sawTraffic = false
        for _ in 0..<8 {
            guard let event = await iterator.next() else {
                break
            }
            if case .traffic(_, let stats) = event, stats.totalReadKB > 0 {
                sawTraffic = true
                break
            }
        }

        XCTAssertTrue(sawTraffic)
        client.disableObservability()
        client.stop()
    }

    func testEasyNetClientDisableObservabilityStopsAutoReconnect() async throws {
        let transport = MockTransportClient()
        let runtime = EasyNetRuntimeClient(
            transport: transport,
            codec: EasyNetPacketCodec(),
            registry: DefaultPluginRegistry()
        )
        let client = EasyNetClient(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )

        client.configureObservability(
            RuntimeClientObservabilityOptions(
                reconnect: RuntimeReconnectOptions(maxAttempts: 1, backoff: .fixed(0.01))
            )
        )
        client.disableObservability()
        client.start()
        transport.emit(.connected(connection))
        transport.emit(.disconnected(connection, .remoteClosed))

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.startInvocations, 1)
        client.stop()
    }
}
