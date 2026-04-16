import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

public final class EasyNetRuntimeServer: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let transport: any TransportServer
    private let codec: any PacketCodec
    private let registry: DefaultPluginRegistry
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private var decoders: [ConnectionID: any PacketDecoder] = [:]
    private var consumeTask: Task<Void, Never>?

    public init(
        transport: any TransportServer,
        codec: any PacketCodec,
        registry: DefaultPluginRegistry
    ) {
        self.transport = transport
        self.codec = codec
        self.registry = registry

        let stream = AsyncStream<RuntimeEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        stop()
        eventContinuation.finish()
    }

    public func start() async throws {
        guard consumeTask == nil else { return }

        consumeTask = Task { [weak self] in
            await self?.consumeTransportEvents()
        }
        try await transport.start()
    }

    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        transport.stop()
    }

    public func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        let buffer = try codec.encode(packet)
        try await transport.send(buffer, to: connectionID)
    }

    public func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        let packet = try registry.encode(message)
        try await send(packet: packet, to: connectionID)
    }

    private func consumeTransportEvents() async {
        for await event in transport.events {
            switch event {
            case .connecting:
                eventContinuation.yield(.stateChanged(.connecting))
            case .connected(let connectionContext):
                guard connectionContext.remoteAddress != nil else {
                    eventContinuation.yield(.stateChanged(.connected))
                    eventContinuation.yield(.connected(connectionContext))
                    continue
                }
                decoders[connectionContext.id] = codec.makeDecoder()
                eventContinuation.yield(.connected(connectionContext))
                let context = RuntimeServerPluginContext(owner: self, scopedConnection: connectionContext)
                await registry.notifyConnected(context: context)
            case .disconnected(let connectionContext, let reason):
                if let connectionContext {
                    decoders.removeValue(forKey: connectionContext.id)
                }
                eventContinuation.yield(.disconnected(connectionContext, reason))
                let context = RuntimeServerPluginContext(owner: self, scopedConnection: connectionContext)
                await registry.notifyDisconnected(reason: reason, context: context)
            case .failed(let error):
                eventContinuation.yield(.stateChanged(.failed))
                eventContinuation.yield(.failure(error))
            case .inboundBytes(let connectionContext, var buffer):
                do {
                    var decoder = decoders[connectionContext.id] ?? codec.makeDecoder()
                    let packets = try decoder.decode(&buffer)
                    decoders[connectionContext.id] = decoder

                    let context = RuntimeServerPluginContext(owner: self, scopedConnection: connectionContext)
                    for packet in packets {
                        eventContinuation.yield(.packet(connectionContext, packet))
                        if let message = try registry.decode(packet) {
                            eventContinuation.yield(.message(connectionContext, message))
                        }
                        for handler in registry.matchingHandlers(for: packet) {
                            try await handler.handle(packet, context: context)
                        }
                    }
                } catch {
                    eventContinuation.yield(.failure(error))
                }
            }
        }
    }
}

private final class RuntimeServerPluginContext: PluginContext, @unchecked Sendable {
    private unowned let owner: EasyNetRuntimeServer
    let connectionContext: ConnectionContext?

    init(owner: EasyNetRuntimeServer, scopedConnection: ConnectionContext?) {
        self.owner = owner
        self.connectionContext = scopedConnection
    }

    func send(packet: ProtocolPacket) async throws {
        guard let connectionID = connectionContext?.id else {
            throw ConnectionCloseReason.transportError("missing_scoped_connection")
        }
        try await owner.send(packet: packet, to: connectionID)
    }

    func send(message: any DomainMessage) async throws {
        guard let connectionID = connectionContext?.id else {
            throw ConnectionCloseReason.transportError("missing_scoped_connection")
        }
        try await owner.send(message: message, to: connectionID)
    }

    func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await owner.send(packet: packet, to: connectionID)
    }

    func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await owner.send(message: message, to: connectionID)
    }
}
