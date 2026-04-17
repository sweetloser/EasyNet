import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport
import NIOCore

final class RuntimeOutboundSender {
    typealias BufferWriter = (ByteBuffer, ConnectionID?) async throws -> Void

    private let codec: any PacketCodec
    private let registry: DefaultPluginRegistry
    private let bufferWriter: BufferWriter

    init(
        codec: any PacketCodec,
        registry: DefaultPluginRegistry,
        bufferWriter: @escaping BufferWriter
    ) {
        self.codec = codec
        self.registry = registry
        self.bufferWriter = bufferWriter
    }

    func send(packet: ProtocolPacket, to connectionID: ConnectionID? = nil) async throws {
        let buffer = try codec.encode(packet)
        try await bufferWriter(buffer, connectionID)
    }

    func send(message: any DomainMessage, to connectionID: ConnectionID? = nil) async throws {
        let packet = try registry.encode(message)
        try await send(packet: packet, to: connectionID)
    }
}
