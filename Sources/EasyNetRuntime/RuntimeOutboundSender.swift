import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport
import NIOCore

final class RuntimeOutboundSender {
    typealias BufferWriter = (ByteBuffer, ConnectionID?) async throws -> Void
    typealias BufferObserver = (Int, ConnectionID?) -> Void

    private let codec: any PacketCodec
    private let registry: DefaultPluginRegistry
    private let bufferWriter: BufferWriter
    private let bufferObserver: BufferObserver?

    init(
        codec: any PacketCodec,
        registry: DefaultPluginRegistry,
        bufferWriter: @escaping BufferWriter,
        bufferObserver: BufferObserver? = nil
    ) {
        self.codec = codec
        self.registry = registry
        self.bufferWriter = bufferWriter
        self.bufferObserver = bufferObserver
    }

    @discardableResult
    func send(packet: ProtocolPacket, to connectionID: ConnectionID? = nil) async throws -> Int {
        let buffer = try codec.encode(packet)
        let byteCount = buffer.readableBytes
        try await bufferWriter(buffer, connectionID)
        bufferObserver?(byteCount, connectionID)
        return byteCount
    }

    @discardableResult
    func send(message: any DomainMessage, to connectionID: ConnectionID? = nil) async throws -> Int {
        let packet = try registry.encode(message)
        return try await send(packet: packet, to: connectionID)
    }
}
