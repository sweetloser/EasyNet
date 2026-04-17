import Foundation
import NIOCore

public enum ProtocolPacketMagic: UInt16, Sendable {
    case request = 0x0001
    case response = 0x0002
    case event = 0x0003
    case unknown = 0xFFFF
}

public enum ProtocolCodecMethod: UInt8, Sendable {
    case binary = 0x01
    case json = 0x02
}

public struct ProtocolHeader: Sendable, CustomStringConvertible {
    public static let byteLength = 20

    public var magic: ProtocolPacketMagic
    public var version: UInt8
    public var codec: ProtocolCodecMethod
    public var command: UInt16
    public var session: UInt16
    public var flags: UInt8
    public var sequence: UInt32
    public var status: UInt8
    public var checksum: UInt16
    public var length: UInt32

    public init(
        magic: ProtocolPacketMagic = .request,
        version: UInt8 = 1,
        codec: ProtocolCodecMethod = .binary,
        command: UInt16,
        session: UInt16 = 0,
        flags: UInt8 = 0,
        sequence: UInt32 = 0,
        status: UInt8 = 0,
        checksum: UInt16 = 0,
        length: UInt32 = 0
    ) {
        self.magic = magic
        self.version = version
        self.codec = codec
        self.command = command
        self.session = session
        self.flags = flags
        self.sequence = sequence
        self.status = status
        self.checksum = checksum
        self.length = length
    }

    public var description: String {
        "ProtocolHeader(magic: \(magic), version: \(version), codec: \(codec), command: \(command), session: \(session), flags: \(flags), sequence: \(sequence), status: \(status), checksum: \(checksum), length: \(length))"
    }
}

public struct ProtocolPacket: Sendable, CustomStringConvertible {
    public var header: ProtocolHeader
    public var payload: [UInt8]

    public init(header: ProtocolHeader, payload: [UInt8] = []) {
        self.header = header
        self.payload = payload
        self.header.length = UInt32(payload.count)
    }

    public var description: String {
        "ProtocolPacket(header: \(header), payloadCount: \(payload.count))"
    }
}

public protocol PacketEncoder {
    func encode(_ packet: ProtocolPacket) throws -> ByteBuffer
}

public protocol PacketDecoder {
    mutating func decode(_ buffer: inout ByteBuffer) throws -> [ProtocolPacket]
}

public protocol PacketCodec: PacketEncoder {
    func makeDecoder() -> PacketDecoder
}
