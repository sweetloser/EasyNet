import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

package enum SystemCommand {
    package static let handshake: UInt16 = 0x0001
    package static let heartbeat: UInt16 = 0x0002
}

public struct HandshakeMessage: DomainMessage {
    public let acknowledged: Bool

    public init(acknowledged: Bool) {
        self.acknowledged = acknowledged
    }
}

public struct HeartbeatMessage: DomainMessage {
    public init() {}
}

public final class SystemHandshakePlugin: ProtocolPlugin, PacketMapper, PacketRouteHandler, PluginLifecycleHook {
    public let key = "system.handshake"

    public init() {}

    public func setup(in registry: PluginRegistry) {
        registry.register(mapper: self)
        registry.register(handler: self)
        registry.register(lifecycle: self)
    }

    public func didConnect(context: PluginContext) async {
        let header = ProtocolHeader(magic: .request, command: SystemCommand.handshake)
        let packet = ProtocolPacket(header: header)
        try? await context.send(packet: packet)
    }

    public func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        guard packet.header.command == SystemCommand.handshake else {
            return nil
        }
        return HandshakeMessage(acknowledged: packet.header.magic == .response)
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard let message = message as? HandshakeMessage else {
            return nil
        }

        let magic: ProtocolPacketMagic = message.acknowledged ? .response : .request
        return ProtocolPacket(header: ProtocolHeader(magic: magic, command: SystemCommand.handshake))
    }

    public func canHandle(_ packet: ProtocolPacket) -> Bool {
        packet.header.command == SystemCommand.handshake && packet.header.magic == .request
    }

    public func handle(_ packet: ProtocolPacket, context: PluginContext) async throws {
        let response = ProtocolPacket(header: ProtocolHeader(magic: .response, command: SystemCommand.handshake, session: packet.header.session))
        try await context.send(packet: response)
    }
}

public final class SystemHeartbeatPlugin: ProtocolPlugin, PacketMapper, PacketRouteHandler {
    public let key = "system.heartbeat"

    public init() {}

    public func setup(in registry: PluginRegistry) {
        registry.register(mapper: self)
        registry.register(handler: self)
    }

    public func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        guard packet.header.command == SystemCommand.heartbeat else {
            return nil
        }
        return HeartbeatMessage()
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket? {
        guard message is HeartbeatMessage else {
            return nil
        }
        return ProtocolPacket(header: ProtocolHeader(magic: .event, command: SystemCommand.heartbeat))
    }

    public func canHandle(_ packet: ProtocolPacket) -> Bool {
        packet.header.command == SystemCommand.heartbeat && packet.header.magic == .request
    }

    public func handle(_ packet: ProtocolPacket, context: PluginContext) async throws {
        let response = ProtocolPacket(header: ProtocolHeader(magic: .response, command: SystemCommand.heartbeat, session: packet.header.session))
        try await context.send(packet: response)
    }
}
