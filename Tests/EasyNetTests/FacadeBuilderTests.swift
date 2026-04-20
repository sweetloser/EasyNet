import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class FacadeBuilderTests: XCTestCase {
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

    func testBuilderRequiresExplicitClientConfiguration() {
        let builder = EasyNetBuilder().addPlugin(TerminalTextPlugin())

        XCTAssertThrowsError(try builder.buildClient()) { error in
            XCTAssertEqual(error as? EasyNetBuilderError, .missingClientConfiguration)
        }
    }

    func testFacadeTypealiasesExposeRecommendedApiNames() {
        let requestOptions = EasyNetRequestOptions(timeout: 5, retryCount: 1)
        XCTAssertEqual(requestOptions.timeout, 5)
        XCTAssertEqual(requestOptions.retryCount, 1)

        let clientObservability = EasyNetClientObservabilityOptions(
            reconnect: EasyNetReconnectOptions(maxAttempts: 1),
            heartbeat: EasyNetHeartbeatOptions(interval: 30, timeout: 5, maxConsecutiveFailures: 2),
            trafficMonitor: EasyNetTrafficMonitorOptions(interval: 1)
        )
        XCTAssertEqual(clientObservability.reconnect?.maxAttempts, 1)
        XCTAssertEqual(clientObservability.trafficMonitor?.interval, 1)

        let serverObservability = EasyNetServerObservabilityOptions(
            trafficMonitor: EasyNetTrafficMonitorOptions(interval: 2)
        )
        XCTAssertEqual(serverObservability.trafficMonitor?.interval, 2)
    }
}
