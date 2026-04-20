import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class RuntimeClientRequestTests: XCTestCase {
    func testEasyNetClientLabeledPacketRequestReturnsResponse() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)
        let client = EasyNetClient(runtime: runtime)

        client.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestPacket = try registry.encode(TerminalTextMessage(text: "facade", magic: .request, session: 41))
        let responsePacket = try registry.encode(TerminalTextMessage(text: "echo: facade", magic: .response, session: 41))

        let responseBuffer = try codec.encode(responsePacket)
        let responder = Task {
            await waitUntil(timeoutNanoseconds: 2_000_000_000) {
                transport.sentBuffersCount > 0
            }
            transport.emit(.inboundBytes(connection, responseBuffer))
        }

        let packetResult = try await client.request(packet: requestPacket)
        await responder.value
        XCTAssertEqual(packetResult.header.session, 41)
        XCTAssertEqual(packetResult.header.magic, .response)

        client.stop()
    }

    func testEasyNetClientUnlabeledPacketRequestAliasStillWorks() async throws {
        let transport = MockTransportClient()
        let registry = DefaultPluginRegistry()
        registry.install(TerminalTextPlugin())
        let codec = EasyNetPacketCodec()
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)
        let client = EasyNetClient(runtime: runtime)

        client.start()

        let connection = ConnectionContext(id: ConnectionID(), localAddress: "127.0.0.1:5000", remoteAddress: "127.0.0.1:9999")
        transport.emit(.connected(connection))

        let requestPacket = try registry.encode(TerminalTextMessage(text: "alias", magic: .request, session: 42))
        let responsePacket = try registry.encode(TerminalTextMessage(text: "echo: alias", magic: .response, session: 42))

        let responseBuffer = try codec.encode(responsePacket)
        let responder = Task {
            await waitUntil(timeoutNanoseconds: 2_000_000_000) {
                transport.sentBuffersCount > 0
            }
            transport.emit(.inboundBytes(connection, responseBuffer))
        }

        let packetResult = try await client.request(requestPacket)
        await responder.value
        XCTAssertEqual(packetResult.header.session, 42)
        XCTAssertEqual(packetResult.header.magic, .response)

        client.stop()
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
}
