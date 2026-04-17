import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

struct RuntimePacketDispatcher {
    let registry: DefaultPluginRegistry
    let emitPacket: (ConnectionContext, ProtocolPacket) -> Void
    let emitMessage: (ConnectionContext, any DomainMessage) -> Void
    let beforeHandle: (ProtocolPacket) async throws -> Void

    init(
        registry: DefaultPluginRegistry,
        emitPacket: @escaping (ConnectionContext, ProtocolPacket) -> Void,
        emitMessage: @escaping (ConnectionContext, any DomainMessage) -> Void,
        beforeHandle: @escaping (ProtocolPacket) async throws -> Void = { _ in }
    ) {
        self.registry = registry
        self.emitPacket = emitPacket
        self.emitMessage = emitMessage
        self.beforeHandle = beforeHandle
    }

    func dispatch(
        _ packets: [ProtocolPacket],
        from connectionContext: ConnectionContext,
        context: PluginContext
    ) async throws {
        for packet in packets {
            emitPacket(connectionContext, packet)
            try await beforeHandle(packet)

            if let message = try registry.decode(packet) {
                emitMessage(connectionContext, message)
            }

            for handler in registry.matchingHandlers(for: packet) {
                try await handler.handle(packet, context: context)
            }
        }
    }
}
