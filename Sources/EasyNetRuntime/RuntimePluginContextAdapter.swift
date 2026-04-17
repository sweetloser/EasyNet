import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

final class RuntimePluginContextAdapter: PluginContext, @unchecked Sendable {
    typealias PacketSender = @Sendable (ProtocolPacket, ConnectionID) async throws -> Void
    typealias MessageSender = @Sendable (any DomainMessage, ConnectionID) async throws -> Void
    typealias ScopedConnectionProvider = @Sendable () -> ConnectionContext?

    private let scopedConnectionProvider: ScopedConnectionProvider
    private let packetSender: PacketSender
    private let messageSender: MessageSender

    init(
        scopedConnectionProvider: @escaping ScopedConnectionProvider,
        packetSender: @escaping PacketSender,
        messageSender: @escaping MessageSender
    ) {
        self.scopedConnectionProvider = scopedConnectionProvider
        self.packetSender = packetSender
        self.messageSender = messageSender
    }

    var connectionContext: ConnectionContext? {
        scopedConnectionProvider()
    }

    func send(packet: ProtocolPacket) async throws {
        let connectionID = try requireScopedConnectionID()
        try await packetSender(packet, connectionID)
    }

    func send(message: any DomainMessage) async throws {
        let connectionID = try requireScopedConnectionID()
        try await messageSender(message, connectionID)
    }

    func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await ensureConnectionIsReachable(connectionID)
        try await packetSender(packet, connectionID)
    }

    func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await ensureConnectionIsReachable(connectionID)
        try await messageSender(message, connectionID)
    }

    private func requireScopedConnectionID() throws -> ConnectionID {
        guard let connectionID = connectionContext?.id else {
            throw ConnectionCloseReason.transportError("missing_scoped_connection")
        }
        return connectionID
    }

    private func ensureConnectionIsReachable(_ connectionID: ConnectionID) async throws {
        if let scopedConnectionID = connectionContext?.id, scopedConnectionID != connectionID {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
    }
}
