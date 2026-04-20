import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

public final class EasyNetRuntimeServer: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let transport: any TransportServer
    private let codec: any PacketCodec
    private let registry: DefaultPluginRegistry
    private let outboundSender: RuntimeOutboundSender
    private let decoderStore: RuntimeConnectionDecoderStore
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let trafficMonitor: RuntimeTrafficMonitor
    private var consumeTask: Task<Void, Never>?

    package init(
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
        self.trafficMonitor = RuntimeTrafficMonitor(
            emit: { [continuation = stream.continuation] connectionContext, stats in
                continuation.yield(.traffic(connectionContext, stats))
            }
        )
        self.outboundSender = RuntimeOutboundSender(
            codec: codec,
            registry: registry,
            bufferWriter: { [transport] buffer, connectionID in
                guard let connectionID else {
                    throw ConnectionCloseReason.transportError("missing_scoped_connection")
                }
                try await transport.send(buffer, to: connectionID)
            }
        )
        self.decoderStore = RuntimeConnectionDecoderStore(
            makeDecoder: { codec.makeDecoder() }
        )
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
        let trafficMonitor = self.trafficMonitor
        Task {
            await trafficMonitor.disable()
        }
        transport.stop()
    }

    public func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        let byteCount = try await outboundSender.send(packet: packet, to: connectionID)
        await trafficMonitor.recordWrite(byteCount)
    }

    public func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        let byteCount = try await outboundSender.send(message: message, to: connectionID)
        await trafficMonitor.recordWrite(byteCount)
    }

    public func enableTrafficMonitor(_ options: RuntimeTrafficMonitorOptions) {
        let trafficMonitor = self.trafficMonitor
        Task {
            await trafficMonitor.enable(options, connectionContext: nil)
        }
    }

    public func disableTrafficMonitor() {
        let trafficMonitor = self.trafficMonitor
        Task {
            await trafficMonitor.disable()
        }
    }

    private func consumeTransportEvents() async {
        let emitter = RuntimeEventEmitter(continuation: eventContinuation)
        let dispatcher = emitter.makePacketDispatcher(registry: registry)
        let inboundPipeline = RuntimeServerInboundPipeline(
            decoderStore: decoderStore,
            dispatcher: dispatcher,
            makeContext: { [unowned self] connectionContext in
                self.makePluginContext(scopedConnection: connectionContext)
            }
        )
        let lifecycleCoordinator = RuntimeServerConnectionLifecycleCoordinator(
            decoderStore: decoderStore,
            emitter: emitter,
            makeContext: { [unowned self] scopedConnection in
                self.makePluginContext(scopedConnection: scopedConnection)
            },
            notifyConnected: { [registry] context in
                await registry.notifyConnected(context: context)
            },
            notifyDisconnected: { [registry] reason, context in
                await registry.notifyDisconnected(reason: reason, context: context)
            }
        )

        for await event in transport.events {
            switch event {
            case .connecting:
                emitter.stateChanged(.connecting)
            case .connected(let connectionContext):
                await lifecycleCoordinator.handleConnected(connectionContext)
            case .disconnected(let connectionContext, let reason):
                await lifecycleCoordinator.handleDisconnected(connectionContext, reason: reason)
            case .failed(let error):
                emitter.stateChanged(.failed)
                emitter.failure(error)
            case .inboundBytes(let connectionContext, var buffer):
                do {
                    await trafficMonitor.recordRead(buffer.readableBytes)
                    try await inboundPipeline.process(&buffer, from: connectionContext)
                } catch {
                    emitter.failure(error)
                }
            }
        }
    }

    private func makePluginContext(scopedConnection: ConnectionContext?) -> RuntimePluginContextAdapter {
        RuntimePluginContextAdapter(
            scopedConnectionProvider: { scopedConnection },
            packetSender: { [unowned self] packet, connectionID in
                try await self.send(packet: packet, to: connectionID)
            },
            messageSender: { [unowned self] message, connectionID in
                try await self.send(message: message, to: connectionID)
            }
        )
    }
}
