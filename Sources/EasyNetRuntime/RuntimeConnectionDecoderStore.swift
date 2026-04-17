import EasyNetProtocolCore
import EasyNetTransport
import NIOCore

final class RuntimeConnectionDecoderStore: @unchecked Sendable {
    private let makeDecoder: () -> any PacketDecoder
    private var decoders: [ConnectionID: any PacketDecoder] = [:]

    init(makeDecoder: @escaping () -> any PacketDecoder) {
        self.makeDecoder = makeDecoder
    }

    func connect(_ connectionContext: ConnectionContext) {
        decoders[connectionContext.id] = makeDecoder()
    }

    func disconnect(_ connectionContext: ConnectionContext?) {
        guard let connectionContext else {
            return
        }
        decoders.removeValue(forKey: connectionContext.id)
    }

    func decode(_ buffer: inout ByteBuffer, from connectionContext: ConnectionContext) throws -> [ProtocolPacket] {
        var decoder = decoders[connectionContext.id] ?? makeDecoder()
        let packets = try decoder.decode(&buffer)
        decoders[connectionContext.id] = decoder
        return packets
    }
}
