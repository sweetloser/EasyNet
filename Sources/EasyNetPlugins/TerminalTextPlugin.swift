import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin

package enum TerminalDemoCommand {
    package static let textMessage: UInt16 = 0x1001
}

public struct TerminalTextMessage: DomainMessage {
    public let text: String
    public let magic: ProtocolPacketMagic
    public let session: UInt16

    public init(text: String, magic: ProtocolPacketMagic = .event, session: UInt16 = 0) {
        self.text = text
        self.magic = magic
        self.session = session
    }
}

public final class TerminalTextPlugin: ProtocolPlugin, PacketMapper, PacketRouteHandler {
    public let key = "demo.terminal.text"

    private let serializer: any PayloadSerializer

    public init() {
        self.serializer = JSONPayloadSerializer()
    }

    public init(serializer: any PayloadSerializer) {
        self.serializer = serializer
    }

    public func setup(in registry: PluginRegistry) {
        registry.register(mapper: self)
        registry.register(handler: self)
    }

    public func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        guard packet.header.command == TerminalDemoCommand.textMessage else {
            return nil
        }
        let payload = try serializer.decode(TerminalTextPayload.self, from: packet.payload)
        return TerminalTextMessage(
            text: payload.text,
            magic: packet.header.magic,
            session: packet.header.session
        )
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard let message = message as? TerminalTextMessage else {
            return nil
        }
        let payload = TerminalTextPayload(text: message.text)
        let data = try serializer.encode(payload)
        let header = ProtocolHeader(
            magic: message.magic,
            version: 1,
            codec: .json,
            command: TerminalDemoCommand.textMessage,
            session: message.session
        )
        return ProtocolPacket(header: header, payload: data)
    }

    public func canHandle(_ packet: ProtocolPacket) -> Bool {
        packet.header.command == TerminalDemoCommand.textMessage && packet.header.magic == .request
    }

    public func handle(_ packet: ProtocolPacket, context: PluginContext) async throws {
        guard let message = try decode(packet) as? TerminalTextMessage else {
            return
        }

        let response = TerminalTextMessage(
            text: "echo: \(message.text)",
            magic: .response,
            session: packet.header.session
        )
        try await context.send(message: response)
    }
}

private struct TerminalTextPayload: Codable {
    let text: String
}
