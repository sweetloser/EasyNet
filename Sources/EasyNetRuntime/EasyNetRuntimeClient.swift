import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

public final class EasyNetRuntimeClient: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let transport: any TransportClient
    private let codec: any PacketCodec
    private let registry: DefaultPluginRegistry
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let requestCoordinator = RequestCoordinator()
    private var decoder: any PacketDecoder
    private var connectionContext: ConnectionContext?
    private var consumeTask: Task<Void, Never>?

    public init(
        transport: any TransportClient,
        codec: any PacketCodec,
        registry: DefaultPluginRegistry
    ) {
        self.transport = transport
        self.codec = codec
        self.registry = registry
        self.decoder = codec.makeDecoder()

        let stream = AsyncStream<RuntimeEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        stop()
        eventContinuation.finish()
    }

    public func start() {
        guard consumeTask == nil else { return }

        consumeTask = Task { [weak self] in
            await self?.consumeTransportEvents()
        }
        transport.start()
    }

    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        transport.stop()
    }

    public func send(packet: ProtocolPacket) async throws {
        let buffer = try codec.encode(packet)
        try await transport.send(buffer)
    }

    public func send(message: any DomainMessage) async throws {
        let packet = try registry.encode(message)
        try await send(packet: packet)
    }

    public func request(_ packet: ProtocolPacket) async throws -> ProtocolPacket {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await requestCoordinator.register(RequestKey(session: packet.header.session), continuation: continuation)
                do {
                    try await send(packet: packet)
                } catch {
                    await requestCoordinator.failAll(error)
                }
            }
        }
    }

    private func consumeTransportEvents() async {
        let context = RuntimePluginContext(owner: self)

        for await event in transport.events {
            switch event {
            case .connecting:
                eventContinuation.yield(.stateChanged(.connecting))
            case .connected(let connectionContext):
                self.connectionContext = connectionContext
                eventContinuation.yield(.stateChanged(.connected))
                eventContinuation.yield(.connected(connectionContext))
                await registry.notifyConnected(context: context)
            case .disconnected(let connectionContext, let reason):
                self.connectionContext = nil
                eventContinuation.yield(.stateChanged(.disconnected))
                eventContinuation.yield(.disconnected(connectionContext, reason))
                await requestCoordinator.failAll(reason)
                await registry.notifyDisconnected(reason: reason, context: context)
            case .failed(let error):
                eventContinuation.yield(.stateChanged(.failed))
                eventContinuation.yield(.failure(error))
                await requestCoordinator.failAll(error)
            case .inboundBytes(let connectionContext, var buffer):
                do {
                    let packets = try decoder.decode(&buffer)
                    for packet in packets {
                        eventContinuation.yield(.packet(connectionContext, packet))
                        if packet.header.kind == .response {
                            await requestCoordinator.resolve(packet)
                        }
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

    fileprivate func currentConnectionContext() -> ConnectionContext? {
        connectionContext
    }
}

private final class RuntimePluginContext: PluginContext, @unchecked Sendable {
    private unowned let owner: EasyNetRuntimeClient

    init(owner: EasyNetRuntimeClient) {
        self.owner = owner
    }

    var connectionContext: ConnectionContext? {
        owner.currentConnectionContext()
    }

    func send(packet: ProtocolPacket) async throws {
        try await owner.send(packet: packet)
    }

    func send(message: any DomainMessage) async throws {
        try await owner.send(message: message)
    }

    func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        if owner.currentConnectionContext()?.id != connectionID {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
        try await owner.send(packet: packet)
    }

    func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        if owner.currentConnectionContext()?.id != connectionID {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
        try await owner.send(message: message)
    }
}
