import EasyNetProtocolPlugin
import EasyNetTransport

final class RuntimeServerConnectionLifecycleCoordinator {
    private let decoderStore: RuntimeConnectionDecoderStore
    private let emitter: RuntimeEventEmitter
    private let makeContext: (ConnectionContext?) -> PluginContext
    private let notifyConnected: (PluginContext) async -> Void
    private let notifyDisconnected: (ConnectionCloseReason, PluginContext) async -> Void

    init(
        decoderStore: RuntimeConnectionDecoderStore,
        emitter: RuntimeEventEmitter,
        makeContext: @escaping (ConnectionContext?) -> PluginContext,
        notifyConnected: @escaping (PluginContext) async -> Void,
        notifyDisconnected: @escaping (ConnectionCloseReason, PluginContext) async -> Void
    ) {
        self.decoderStore = decoderStore
        self.emitter = emitter
        self.makeContext = makeContext
        self.notifyConnected = notifyConnected
        self.notifyDisconnected = notifyDisconnected
    }

    func handleConnected(_ connectionContext: ConnectionContext) async {
        guard connectionContext.remoteAddress != nil else {
            emitter.stateChanged(.connected)
            emitter.connected(connectionContext)
            return
        }

        decoderStore.connect(connectionContext)
        emitter.connected(connectionContext)
        await notifyConnected(makeContext(connectionContext))
    }

    func handleDisconnected(_ connectionContext: ConnectionContext?, reason: ConnectionCloseReason) async {
        decoderStore.disconnect(connectionContext)
        emitter.disconnected(connectionContext, reason: reason)
        await notifyDisconnected(reason, makeContext(connectionContext))
    }
}
