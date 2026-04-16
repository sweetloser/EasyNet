import Foundation

public protocol PayloadSerializer {
    func encode<T: Encodable>(_ value: T) throws -> [UInt8]
    func decode<T: Decodable>(_ type: T.Type, from data: [UInt8]) throws -> T
}

public struct JSONPayloadSerializer: PayloadSerializer {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        try Array(encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: [UInt8]) throws -> T {
        try decoder.decode(type, from: Data(data))
    }
}

public struct RawPayloadSerializer: PayloadSerializer {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        if let data = value as? Data {
            return [UInt8](data)
        }
        throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "RawPayloadSerializer only supports Data"))
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: [UInt8]) throws -> T {
        if type == Data.self, let value = Data(data) as? T {
            return value
        }
        throw DecodingError.typeMismatch(type, .init(codingPath: [], debugDescription: "RawPayloadSerializer only supports Data"))
    }
}
