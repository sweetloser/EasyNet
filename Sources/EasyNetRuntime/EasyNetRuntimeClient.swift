import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

public final class EasyNetRuntimeClient: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let transport: any TransportClient
    private let registry: DefaultPluginRegistry
    private let outboundSender: RuntimeOutboundSender
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let requestOrchestrator = RuntimeRequestOrchestrator()
    private var decoder: any PacketDecoder
    private var connectionContext: ConnectionContext?
    private var consumeTask: Task<Void, Never>?

    public init(
        transport: any TransportClient,
        codec: any PacketCodec,
        registry: DefaultPluginRegistry
    ) {
        self.transport = transport
        self.registry = registry
        self.outboundSender = RuntimeOutboundSender(
            codec: codec,
            registry: registry,
            bufferWriter: { [transport] buffer, connectionID in
                guard connectionID == nil else {
                    throw ConnectionCloseReason.transportError("connection_not_found")
                }
                try await transport.send(buffer)
            }
        )
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
        try await outboundSender.send(packet: packet)
    }

    public func send(message: any DomainMessage) async throws {
        try await outboundSender.send(message: message)
    }

    public func request(_ packet: ProtocolPacket) async throws -> ProtocolPacket {
        try await request(packet, timeout: nil)
    }

    public func request(_ packet: ProtocolPacket, timeout: TimeInterval?) async throws -> ProtocolPacket {
        try await request(packet, options: RuntimeRequestOptions(timeout: timeout))
    }

    public func request(_ packet: ProtocolPacket, options: RuntimeRequestOptions) async throws -> ProtocolPacket {
        try await requestOrchestrator.request(packet, options: options) { [unowned self] packet in
            try await self.send(packet: packet)
        }
    }

    public func request(message: any DomainMessage) async throws -> ProtocolPacket {
        try await request(message: message, timeout: nil)
    }

    public func request(message: any DomainMessage, timeout: TimeInterval?) async throws -> ProtocolPacket {
        try await request(message: message, options: RuntimeRequestOptions(timeout: timeout))
    }

    public func request(message: any DomainMessage, options: RuntimeRequestOptions) async throws -> ProtocolPacket {
        let packet = try registry.encode(message)
        return try await request(packet, options: options)
    }

    public func request<Response: DomainMessage>(
        message: any DomainMessage,
        as responseType: Response.Type,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        try await request(
            message: message,
            as: responseType,
            options: RuntimeRequestOptions(timeout: timeout)
        )
    }

    public func request<Response: DomainMessage>(
        message: any DomainMessage,
        as responseType: Response.Type,
        options: RuntimeRequestOptions
    ) async throws -> Response {
        let responsePacket = try await request(message: message, options: options)
        guard let responseMessage = try registry.decode(responsePacket) else {
            throw RuntimeRequestError.responseNotMapped(command: responsePacket.header.command)
        }
        guard let typedResponse = responseMessage as? Response else {
            throw RuntimeRequestError.unexpectedResponseType(
                expected: String(reflecting: responseType),
                actual: String(reflecting: type(of: responseMessage))
            )
        }
        return typedResponse
    }

    private func consumeTransportEvents() async {
        let emitter = RuntimeEventEmitter(continuation: eventContinuation)
        let requestOrchestrator = self.requestOrchestrator
        let dispatcher = emitter.makePacketDispatcher(
            registry: registry,
            beforeHandle: { packet in
                await requestOrchestrator.resolveIfNeeded(packet)
            }
        )

        for await event in transport.events {
            switch event {
            case .connecting:
                emitter.stateChanged(.connecting)
            case .connected(let connectionContext):
                self.connectionContext = connectionContext
                emitter.stateChanged(.connected)
                emitter.connected(connectionContext)
                let context = makePluginContext(scopedConnection: connectionContext)
                await registry.notifyConnected(context: context)
            case .disconnected(let connectionContext, let reason):
                self.connectionContext = nil
                emitter.stateChanged(.disconnected)
                emitter.disconnected(connectionContext, reason: reason)
                await requestOrchestrator.failAll(reason)
                let context = makePluginContext(scopedConnection: connectionContext)
                await registry.notifyDisconnected(reason: reason, context: context)
            case .failed(let error):
                emitter.stateChanged(.failed)
                emitter.failure(error)
                await requestOrchestrator.failAll(error)
            case .inboundBytes(let connectionContext, var buffer):
                do {
                    let packets = try decoder.decode(&buffer)
                    let context = makePluginContext(scopedConnection: connectionContext)
                    try await dispatcher.dispatch(packets, from: connectionContext, context: context)
                } catch {
                    emitter.failure(error)
                }
            }
        }
    }

    private func makePluginContext(scopedConnection: ConnectionContext?) -> RuntimePluginContextAdapter {
        RuntimePluginContextAdapter(
            scopedConnectionProvider: { [weak self] in
                if let scopedConnection {
                    return scopedConnection
                }
                return self?.currentConnectionContext()
            },
            packetSender: { [weak self] packet, connectionID in
                guard let self else {
                    throw ConnectionCloseReason.transportError("runtime_deallocated")
                }
                try await self.send(packet: packet, to: connectionID)
            },
            messageSender: { [weak self] message, connectionID in
                guard let self else {
                    throw ConnectionCloseReason.transportError("runtime_deallocated")
                }
                try await self.send(message: message, to: connectionID)
            }
        )
    }

    private func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        guard currentConnectionContext()?.id == connectionID else {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
        try await outboundSender.send(packet: packet)
    }

    private func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        guard currentConnectionContext()?.id == connectionID else {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
        try await outboundSender.send(message: message)
    }

    fileprivate func currentConnectionContext() -> ConnectionContext? {
        connectionContext
    }
}
