import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin

public enum TerminalDemoCommand {
    public static let textMessage: UInt16 = 0x1001
}

public struct TerminalTextMessage: DomainMessage {
    public let text: String
    public let kind: ProtocolPacketKind
    public let session: UInt16

    public init(text: String, kind: ProtocolPacketKind = .event, session: UInt16 = 0) {
        self.text = text
        self.kind = kind
        self.session = session
    }
}

public final class TerminalTextPlugin: ProtocolPlugin, PacketMapper, PacketRouteHandler {
    public let key = "demo.terminal.text"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func setup(in registry: PluginRegistry) {
        registry.register(mapper: self)
        registry.register(handler: self)
    }

    public func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        guard packet.header.command == TerminalDemoCommand.textMessage else {
            return nil
        }
        let payload = try decoder.decode(TerminalTextPayload.self, from: Data(packet.payload))
        return TerminalTextMessage(
            text: payload.text,
            kind: packet.header.kind,
            session: packet.header.session
        )
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard let message = message as? TerminalTextMessage else {
            return nil
        }
        let payload = TerminalTextPayload(text: message.text)
        let data = try encoder.encode(payload)
        let header = ProtocolHeader(
            kind: message.kind,
            version: 1,
            codec: .json,
            command: TerminalDemoCommand.textMessage,
            session: message.session
        )
        return ProtocolPacket(header: header, payload: [UInt8](data))
    }

    public func canHandle(_ packet: ProtocolPacket) -> Bool {
        packet.header.command == TerminalDemoCommand.textMessage && packet.header.kind == .request
    }

    public func handle(_ packet: ProtocolPacket, context: PluginContext) async throws {
        guard let message = try decode(packet) as? TerminalTextMessage else {
            return
        }

        let response = TerminalTextMessage(
            text: "echo: \(message.text)",
            kind: .response,
            session: packet.header.session
        )
        try await context.send(message: response)
    }
}

private struct TerminalTextPayload: Codable {
    let text: String
}
