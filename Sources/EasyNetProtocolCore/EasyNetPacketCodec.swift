import Foundation
import NIOCore

public enum ProtocolCodecError: Error {
    case insufficientData
    case invalidCodec(UInt8)
}

public struct EasyNetPacketCodec: PacketCodec {
    private let endianness: Endianness

    public init(endianness: Endianness = .little) {
        self.endianness = endianness
    }

    public func encode(_ packet: ProtocolPacket) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: Int(ProtocolHeader.byteLength + packet.payload.count))
        let header = packet.header

        buffer.writeInteger(header.kind.rawValue, endianness: endianness, as: UInt16.self)
        buffer.writeInteger(header.version, endianness: endianness, as: UInt8.self)
        buffer.writeInteger(header.codec.rawValue, endianness: endianness, as: UInt8.self)
        buffer.writeInteger(header.command, endianness: endianness, as: UInt16.self)
        buffer.writeInteger(header.session, endianness: endianness, as: UInt16.self)
        buffer.writeInteger(header.flags, endianness: endianness, as: UInt8.self)
        buffer.writeInteger(header.sequence, endianness: endianness, as: UInt32.self)
        buffer.writeInteger(UInt32(packet.payload.count), endianness: endianness, as: UInt32.self)
        buffer.writeInteger(header.status, endianness: endianness, as: UInt8.self)
        buffer.writeInteger(header.checksum, endianness: endianness, as: UInt16.self)
        buffer.writeBytes(packet.payload)

        return buffer
    }

    public func makeDecoder() -> PacketDecoder {
        EasyNetPacketDecoder(endianness: endianness)
    }
}

public struct EasyNetPacketDecoder: PacketDecoder {
    private let endianness: Endianness

    public init(endianness: Endianness = .little) {
        self.endianness = endianness
    }

    public mutating func decode(_ buffer: inout ByteBuffer) throws -> [ProtocolPacket] {
        var packets: [ProtocolPacket] = []

        while buffer.readableBytes >= ProtocolHeader.byteLength {
            guard let kindRaw = buffer.getInteger(at: buffer.readerIndex, endianness: endianness, as: UInt16.self),
                  let version = buffer.getInteger(at: buffer.readerIndex + 2, endianness: endianness, as: UInt8.self),
                  let codecRaw = buffer.getInteger(at: buffer.readerIndex + 3, endianness: endianness, as: UInt8.self),
                  let command = buffer.getInteger(at: buffer.readerIndex + 4, endianness: endianness, as: UInt16.self),
                  let session = buffer.getInteger(at: buffer.readerIndex + 6, endianness: endianness, as: UInt16.self),
                  let flags = buffer.getInteger(at: buffer.readerIndex + 8, endianness: endianness, as: UInt8.self),
                  let sequence = buffer.getInteger(at: buffer.readerIndex + 9, endianness: endianness, as: UInt32.self),
                  let length = buffer.getInteger(at: buffer.readerIndex + 13, endianness: endianness, as: UInt32.self),
                  let status = buffer.getInteger(at: buffer.readerIndex + 17, endianness: endianness, as: UInt8.self),
                  let checksum = buffer.getInteger(at: buffer.readerIndex + 18, endianness: endianness, as: UInt16.self) else {
                throw ProtocolCodecError.insufficientData
            }

            let frameLength = ProtocolHeader.byteLength + Int(length)
            guard buffer.readableBytes >= frameLength else {
                break
            }

            _ = buffer.readSlice(length: ProtocolHeader.byteLength)
            let payload = buffer.readBytes(length: Int(length)) ?? []

            guard let codec = ProtocolCodecMethod(rawValue: codecRaw) else {
                throw ProtocolCodecError.invalidCodec(codecRaw)
            }

            let header = ProtocolHeader(
                kind: ProtocolPacketKind(rawValue: kindRaw) ?? .unknown,
                version: version,
                codec: codec,
                command: command,
                session: session,
                flags: flags,
                sequence: sequence,
                status: status,
                checksum: checksum,
                length: length
            )
            packets.append(ProtocolPacket(header: header, payload: payload))
        }

        return packets
    }
}
