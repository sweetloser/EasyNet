import XCTest
import Foundation
import NIOCore
@testable import EasyNet
@testable import EasyNetPlugins
@testable import EasyNetProtocolCore
@testable import EasyNetProtocolPlugin
@testable import EasyNetRuntime
@testable import EasyNetTransport

final class PluginIntegrationTests: XCTestCase {
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
