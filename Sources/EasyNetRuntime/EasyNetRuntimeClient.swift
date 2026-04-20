import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

private enum RuntimeSystemCommand {
    static let heartbeat: UInt16 = 0x0002
}

public final class EasyNetRuntimeClient: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let transport: any TransportClient
    private let registry: DefaultPluginRegistry
    private let outboundSender: RuntimeOutboundSender
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let requestOrchestrator = RuntimeRequestOrchestrator()
    private let trafficMonitor: RuntimeTrafficMonitor
    private var decoder: any PacketDecoder
    private var connectionContext: ConnectionContext?
    private var consumeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatOptions: RuntimeHeartbeatOptions?
    private var reconnectOptions: RuntimeReconnectOptions?
    private var reconnectAttempt = 0

    package init(
        transport: any TransportClient,
        codec: any PacketCodec,
        registry: DefaultPluginRegistry
    ) {
        self.transport = transport
        self.registry = registry
        let stream = AsyncStream<RuntimeEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
        self.trafficMonitor = RuntimeTrafficMonitor(
            emit: { [continuation = stream.continuation] connectionContext, stats in
                continuation.yield(.traffic(connectionContext, stats))
            }
        )
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatOptions = nil
        reconnectOptions = nil
        reconnectAttempt = 0
        transport.stop()
    }

    public func enableAutoReconnect(_ options: RuntimeReconnectOptions) {
        reconnectOptions = options
        reconnectAttempt = 0
    }

    public func disableAutoReconnect() {
        reconnectOptions = nil
        reconnectAttempt = 0
    }

    public func enableHeartbeat(_ options: RuntimeHeartbeatOptions) {
        heartbeatOptions = options
        if connectionContext != nil {
            startHeartbeatLoop()
        }
    }

    public func disableHeartbeat() {
        heartbeatOptions = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    public func enableTrafficMonitor(_ options: RuntimeTrafficMonitorOptions) {
        let connectionContext = self.connectionContext
        Task {
            await trafficMonitor.enable(options, connectionContext: connectionContext)
        }
    }

    public func disableTrafficMonitor() {
        Task {
            await trafficMonitor.disable()
        }
    }

    public func send(packet: ProtocolPacket) async throws {
        let byteCount = try await outboundSender.send(packet: packet)
        await trafficMonitor.recordWrite(byteCount)
    }

    public func send(message: any DomainMessage) async throws {
        let byteCount = try await outboundSender.send(message: message)
        await trafficMonitor.recordWrite(byteCount)
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
                reconnectAttempt = 0
                Task {
                    await trafficMonitor.connected(connectionContext)
                }
                startHeartbeatLoop()
                emitter.stateChanged(.connected)
                emitter.connected(connectionContext)
                let context = makePluginContext(scopedConnection: connectionContext)
                await registry.notifyConnected(context: context)
            case .disconnected(let connectionContext, let reason):
                self.connectionContext = nil
                heartbeatTask?.cancel()
                heartbeatTask = nil
                Task {
                    await trafficMonitor.disconnected()
                }
                emitter.stateChanged(.disconnected)
                emitter.disconnected(connectionContext, reason: reason)
                await requestOrchestrator.failAll(reason)
                let context = makePluginContext(scopedConnection: connectionContext)
                await registry.notifyDisconnected(reason: reason, context: context)
                guard case .localClosed = reason else {
                    await scheduleReconnectIfNeeded()
                    continue
                }
            case .failed(let error):
                heartbeatTask?.cancel()
                heartbeatTask = nil
                Task {
                    await trafficMonitor.disconnected()
                }
                emitter.stateChanged(.failed)
                emitter.failure(error)
                await requestOrchestrator.failAll(error)
                await scheduleReconnectIfNeeded()
            case .inboundBytes(let connectionContext, var buffer):
                do {
                    await trafficMonitor.recordRead(buffer.readableBytes)
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

    private func scheduleReconnectIfNeeded() async {
        guard let reconnectOptions else {
            return
        }

        let nextAttempt = reconnectAttempt + 1
        if let maxAttempts = reconnectOptions.maxAttempts, nextAttempt > maxAttempts {
            return
        }

        reconnectAttempt = nextAttempt
        let delay = reconnectOptions.backoff.delay(
            forRetryAttempt: nextAttempt,
            jitter: reconnectOptions.jitter
        )

        if delay > 0 {
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        guard self.reconnectOptions != nil else {
            return
        }

        transport.start()
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        guard let heartbeatOptions else {
            heartbeatTask = nil
            return
        }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            var consecutiveFailures = 0
            while !Task.isCancelled {
                if heartbeatOptions.interval > 0 {
                    let intervalNs = UInt64(heartbeatOptions.interval * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: intervalNs)
                }

                guard !Task.isCancelled, self.currentConnectionContext() != nil else {
                    return
                }

                let packet = ProtocolPacket(
                    header: ProtocolHeader(
                        magic: .request,
                        command: RuntimeSystemCommand.heartbeat
                    )
                )

                do {
                    _ = try await self.request(
                        packet,
                        options: RuntimeRequestOptions(timeout: heartbeatOptions.timeout)
                    )
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= heartbeatOptions.maxConsecutiveFailures {
                        self.eventContinuation.yield(
                            .failure(RuntimeHeartbeatError.lostResponses(count: consecutiveFailures))
                        )
                        return
                    }
                }
            }
        }
    }
}
