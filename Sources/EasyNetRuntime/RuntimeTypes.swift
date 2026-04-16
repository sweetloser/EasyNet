import Foundation
import EasyNetProtocolCore
import EasyNetProtocolPlugin
import EasyNetTransport

public enum RuntimeEvent {
    case stateChanged(ConnectionState)
    case connected(ConnectionContext)
    case disconnected(ConnectionContext?, ConnectionCloseReason)
    case packet(ConnectionContext?, ProtocolPacket)
    case message(ConnectionContext?, any DomainMessage)
    case failure(Error)
}

public struct RequestKey: Hashable, Sendable {
    public let session: UInt16

    public init(session: UInt16) {
        self.session = session
    }
}

public actor RequestCoordinator {
    private var continuations: [RequestKey: CheckedContinuation<ProtocolPacket, Error>] = [:]

    public init() {}

    public func register(_ key: RequestKey, continuation: CheckedContinuation<ProtocolPacket, Error>) {
        continuations[key] = continuation
    }

    public func resolve(_ packet: ProtocolPacket) {
        let key = RequestKey(session: packet.header.session)
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(returning: packet)
    }

    public func failAll(_ error: Error) {
        let values = continuations.values
        continuations.removeAll()

        for continuation in values {
            continuation.resume(throwing: error)
        }
    }
}
