import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class ServerObservabilityTests: XCTestCase {
    func testEasyNetServerTrafficMonitorEmitsTrafficStats() async throws {
        let transport = MockTransportServer()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeServer(
            transport: transport,
            codec: codec,
            registry: registry
        )
        let server = EasyNetServer(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        var iterator = server.events.makeAsyncIterator()

        server.enableTrafficMonitor(RuntimeTrafficMonitorOptions(interval: 0.01))
        try await server.start()
        transport.emit(.connected(connection))

        let outboundPacket = ProtocolPacket(
            header: ProtocolHeader(magic: .event, command: 0x2002, session: 11),
            payload: [1, 2, 3, 4]
        )
        try await server.send(packet: outboundPacket, to: connection.id)

        let inboundPacket = try registry.encode(
            TerminalTextMessage(text: "server-traffic", magic: .request, session: 12)
        )
        let inboundBuffer = try codec.encode(inboundPacket)
        transport.emit(.inboundBytes(connection, inboundBuffer))

        try? await Task.sleep(nanoseconds: 100_000_000)

        var stats: RuntimeTrafficStats?
        for _ in 0..<8 {
            guard let event = await iterator.next() else {
                break
            }
            if case .traffic(_, let trafficStats) = event,
               trafficStats.totalReadKB > 0,
               trafficStats.totalWriteKB > 0 {
                stats = trafficStats
                break
            }
        }

        let trafficStats = try XCTUnwrap(stats)
        XCTAssertGreaterThan(trafficStats.totalReadKB, 0)
        XCTAssertGreaterThan(trafficStats.totalWriteKB, 0)

        server.disableTrafficMonitor()
        server.stop()
    }

    func testEasyNetServerConfigureObservabilityEnablesTrafficMonitor() async throws {
        let transport = MockTransportServer()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeServer(
            transport: transport,
            codec: codec,
            registry: registry
        )
        let server = EasyNetServer(runtime: runtime)
        let connection = ConnectionContext(
            id: ConnectionID(),
            localAddress: "127.0.0.1:9999",
            remoteAddress: "127.0.0.1:5000"
        )
        var iterator = server.events.makeAsyncIterator()

        server.configureObservability(
            RuntimeServerObservabilityOptions(
                trafficMonitor: RuntimeTrafficMonitorOptions(interval: 0.01)
            )
        )
        try await server.start()
        transport.emit(.connected(connection))

        let inboundPacket = try registry.encode(
            TerminalTextMessage(text: "server-observe", magic: .request, session: 13)
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
        server.disableObservability()
        server.stop()
    }
}
