import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

struct RuntimeEventEmitter {
    let continuation: AsyncStream<RuntimeEvent>.Continuation

    func stateChanged(_ state: ConnectionState) {
        continuation.yield(.stateChanged(state))
    }

    func connected(_ connectionContext: ConnectionContext) {
        continuation.yield(.connected(connectionContext))
    }

    func disconnected(_ connectionContext: ConnectionContext?, reason: ConnectionCloseReason) {
        continuation.yield(.disconnected(connectionContext, reason))
    }

    func packet(_ packet: ProtocolPacket, from connectionContext: ConnectionContext) {
        continuation.yield(.packet(connectionContext, packet))
    }

    func message(_ message: any DomainMessage, from connectionContext: ConnectionContext) {
        continuation.yield(.message(connectionContext, message))
    }

    func failure(_ error: Error) {
        continuation.yield(.failure(error))
    }

    func makePacketDispatcher(
        registry: DefaultPluginRegistry,
        beforeHandle: @escaping (ProtocolPacket) async throws -> Void = { _ in }
    ) -> RuntimePacketDispatcher {
        RuntimePacketDispatcher(
            registry: registry,
            emitPacket: { [self] connectionContext, protocolPacket in
                self.packet(protocolPacket, from: connectionContext)
            },
            emitMessage: { [self] connectionContext, domainMessage in
                self.message(domainMessage, from: connectionContext)
            },
            beforeHandle: beforeHandle
        )
    }
}
