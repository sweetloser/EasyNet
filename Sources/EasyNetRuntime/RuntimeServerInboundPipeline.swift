import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport
import NIOCore

struct RuntimeServerInboundPipeline {
    let decoderStore: RuntimeConnectionDecoderStore
    let dispatcher: RuntimePacketDispatcher
    let makeContext: (ConnectionContext) -> PluginContext

    func process(_ buffer: inout ByteBuffer, from connectionContext: ConnectionContext) async throws {
        let packets = try decoderStore.decode(&buffer, from: connectionContext)
        let context = makeContext(connectionContext)
        try await dispatcher.dispatch(packets, from: connectionContext, context: context)
    }
}
