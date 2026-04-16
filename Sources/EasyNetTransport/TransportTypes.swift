import Foundation
import NIOCore

public struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

public struct ConnectionContext: Sendable, CustomStringConvertible {
    public let id: ConnectionID
    public let localAddress: String?
    public let remoteAddress: String?

    public init(id: ConnectionID, localAddress: String? = nil, remoteAddress: String? = nil) {
        self.id = id
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }

    public var description: String {
        "ConnectionContext(id: \(id), local: \(localAddress ?? "nil"), remote: \(remoteAddress ?? "nil"))"
    }
}

public enum ConnectionState: Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected
    case failed
}

public enum ConnectionCloseReason: Error, Sendable, CustomStringConvertible {
    case remoteClosed
    case localClosed
    case transportError(String)

    public var description: String {
        switch self {
        case .remoteClosed:
            return "remote_closed"
        case .localClosed:
            return "local_closed"
        case .transportError(let reason):
            return "transport_error(\(reason))"
        }
    }
}

public struct TransportClientConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let connectTimeoutSeconds: Int64

    public init(host: String, port: Int, connectTimeoutSeconds: Int64 = 10) {
        self.host = host
        self.port = port
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
}

public struct TransportServerConfiguration: Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public enum TransportEvent {
    case connecting
    case connected(ConnectionContext)
    case disconnected(ConnectionContext?, ConnectionCloseReason)
    case failed(Error)
    case inboundBytes(ConnectionContext, ByteBuffer)
}

public protocol TransportClient: AnyObject {
    var state: ConnectionState { get }
    var events: AsyncStream<TransportEvent> { get }

    func start()
    func stop()
    func send(_ buffer: ByteBuffer) async throws
}

public protocol TransportServer: AnyObject {
    var state: ConnectionState { get }
    var events: AsyncStream<TransportEvent> { get }

    func start() async throws
    func stop()
    func send(_ buffer: ByteBuffer, to connectionID: ConnectionID) async throws
}
