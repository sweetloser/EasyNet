import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin

package enum DemoChatCommand {
    package static let message: UInt16 = 0x3001
}

public struct DemoChatMessage: DomainMessage {
    public let room: String
    public let text: String
    public let magic: ProtocolPacketMagic
    public let session: UInt16

    public init(
        room: String,
        text: String,
        magic: ProtocolPacketMagic = .event,
        session: UInt16 = 0
    ) {
        self.room = room
        self.text = text
        self.magic = magic
        self.session = session
    }
}

public final class DemoChatPlugin: ProtocolPlugin, PacketMapper, PacketRouteHandler {
    public let key = "demo.chat"

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
        guard packet.header.command == DemoChatCommand.message else {
            return nil
        }

        let payload = try serializer.decode(DemoChatPayload.self, from: packet.payload)
        return DemoChatMessage(
            room: payload.room,
            text: payload.text,
            magic: packet.header.magic,
            session: packet.header.session
        )
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard let message = message as? DemoChatMessage else {
            return nil
        }

        let payload = DemoChatPayload(room: message.room, text: message.text)
        let data = try serializer.encode(payload)
        let header = ProtocolHeader(
            magic: message.magic,
            version: 1,
            codec: .json,
            command: DemoChatCommand.message,
            session: message.session
        )
        return ProtocolPacket(header: header, payload: data)
    }

    public func canHandle(_ packet: ProtocolPacket) -> Bool {
        packet.header.command == DemoChatCommand.message && packet.header.magic == .request
    }

    public func handle(_ packet: ProtocolPacket, context: PluginContext) async throws {
        guard let message = try decode(packet) as? DemoChatMessage else {
            return
        }

        let response = DemoChatMessage(
            room: message.room,
            text: "ack: \(message.text)",
            magic: .response,
            session: packet.header.session
        )
        try await context.send(message: response)
    }
}

private struct DemoChatPayload: Codable {
    let room: String
    let text: String
}
