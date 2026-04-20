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
    case traffic(ConnectionContext?, RuntimeTrafficStats)
    case failure(Error)
}

public extension RuntimeEvent {
    var connectionContext: ConnectionContext? {
        switch self {
        case .connected(let context):
            return context
        case .disconnected(let context, _):
            return context
        case .packet(let context, _):
            return context
        case .message(let context, _):
            return context
        case .traffic(let context, _):
            return context
        case .stateChanged, .failure:
            return nil
        }
    }

    var connectionState: ConnectionState? {
        guard case .stateChanged(let state) = self else {
            return nil
        }
        return state
    }

    var packetValue: ProtocolPacket? {
        guard case .packet(_, let packet) = self else {
            return nil
        }
        return packet
    }

    var messageValue: (any DomainMessage)? {
        guard case .message(_, let message) = self else {
            return nil
        }
        return message
    }

    var trafficStats: RuntimeTrafficStats? {
        guard case .traffic(_, let stats) = self else {
            return nil
        }
        return stats
    }

    var error: Error? {
        switch self {
        case .disconnected(_, let reason):
            return reason
        case .failure(let error):
            return error
        default:
            return nil
        }
    }

    var isObservabilityEvent: Bool {
        switch self {
        case .traffic, .failure:
            return true
        case .disconnected(_, let reason):
            if case .localClosed = reason {
                return false
            }
            return true
        default:
            return false
        }
    }
}

public enum RuntimeRequestError: Error, Equatable {
    case responseNotMapped(command: UInt16)
    case unexpectedResponseType(expected: String, actual: String)
    case timeout(session: UInt16)
}

public enum RuntimeRetryCondition: Sendable, Equatable {
    case allFailures
    case timeoutOnly
}

public enum RuntimeRetryJitter: Sendable, Equatable {
    case none
    case ratio(Double)

    func apply(to delay: TimeInterval, maxDelay: TimeInterval? = nil, sample: Double) -> TimeInterval {
        guard delay > 0 else {
            return 0
        }

        let normalizedSample = min(max(sample, 0), 1)

        switch self {
        case .none:
            return clamp(delay, maxDelay: maxDelay)
        case .ratio(let ratio):
            let normalizedRatio = max(0, ratio)
            let spread = delay * normalizedRatio
            let lower = max(0, delay - spread)
            let upper = delay + spread
            let jittered = lower + (upper - lower) * normalizedSample
            return clamp(jittered, maxDelay: maxDelay)
        }
    }

    private func clamp(_ value: TimeInterval, maxDelay: TimeInterval?) -> TimeInterval {
        guard let maxDelay else {
            return max(0, value)
        }
        return min(max(0, value), max(0, maxDelay))
    }
}

public enum RuntimeRetryBackoff: Sendable, Equatable {
    case immediate
    case fixed(TimeInterval)
    case exponential(initialDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval?)

    public func delay(
        forRetryAttempt attempt: Int,
        jitter: RuntimeRetryJitter = .none,
        sample: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        let normalizedAttempt = max(1, attempt)

        switch self {
        case .immediate:
            return 0
        case .fixed(let interval):
            return jitter.apply(to: max(0, interval), sample: sample)
        case .exponential(let initialDelay, let multiplier, let maxDelay):
            let baseDelay = max(0, initialDelay)
            let normalizedMultiplier = max(1, multiplier)
            let factor = pow(normalizedMultiplier, Double(normalizedAttempt - 1))
            let computed = baseDelay * factor
            return jitter.apply(to: computed, maxDelay: maxDelay, sample: sample)
        }
    }
}

public struct RuntimeRequestOptions: Sendable, Equatable {
    public let timeout: TimeInterval?
    public let retryCount: Int
    public let retryCondition: RuntimeRetryCondition
    public let retryBackoff: RuntimeRetryBackoff
    public let retryJitter: RuntimeRetryJitter

    public init(
        timeout: TimeInterval? = nil,
        retryCount: Int = 0,
        retryDelay: TimeInterval = 0,
        retryCondition: RuntimeRetryCondition = .allFailures,
        retryJitter: RuntimeRetryJitter = .none
    ) {
        self.timeout = timeout
        self.retryCount = max(0, retryCount)
        self.retryCondition = retryCondition
        self.retryBackoff = retryDelay > 0 ? .fixed(retryDelay) : .immediate
        self.retryJitter = retryJitter
    }

    public init(
        timeout: TimeInterval? = nil,
        retryCount: Int = 0,
        retryCondition: RuntimeRetryCondition,
        retryBackoff: RuntimeRetryBackoff,
        retryJitter: RuntimeRetryJitter = .none
    ) {
        self.timeout = timeout
        self.retryCount = max(0, retryCount)
        self.retryCondition = retryCondition
        self.retryBackoff = retryBackoff
        self.retryJitter = retryJitter
    }
}

public struct RuntimeReconnectOptions: Sendable, Equatable {
    public let maxAttempts: Int?
    public let backoff: RuntimeRetryBackoff
    public let jitter: RuntimeRetryJitter

    public init(
        maxAttempts: Int? = nil,
        backoff: RuntimeRetryBackoff = .immediate,
        jitter: RuntimeRetryJitter = .none
    ) {
        self.maxAttempts = maxAttempts.map { max(0, $0) }
        self.backoff = backoff
        self.jitter = jitter
    }
}

public enum RuntimeHeartbeatError: Error, Equatable {
    case lostResponses(count: Int)
}

public struct RuntimeHeartbeatOptions: Sendable, Equatable {
    public let interval: TimeInterval
    public let timeout: TimeInterval
    public let maxConsecutiveFailures: Int

    public init(
        interval: TimeInterval = 30,
        timeout: TimeInterval = 5,
        maxConsecutiveFailures: Int = 5
    ) {
        self.interval = max(0, interval)
        self.timeout = max(0, timeout)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
    }
}

public struct RuntimeTrafficMonitorOptions: Sendable, Equatable {
    public let interval: TimeInterval

    public init(interval: TimeInterval = 1) {
        self.interval = max(0, interval)
    }
}

public struct RuntimeTrafficStats: Sendable, Equatable {
    public let readKBps: Double
    public let writeKBps: Double
    public let totalReadKB: Double
    public let totalWriteKB: Double

    public init(
        readKBps: Double,
        writeKBps: Double,
        totalReadKB: Double,
        totalWriteKB: Double
    ) {
        self.readKBps = readKBps
        self.writeKBps = writeKBps
        self.totalReadKB = totalReadKB
        self.totalWriteKB = totalWriteKB
    }
}

public struct RuntimeClientObservabilityOptions: Sendable, Equatable {
    public let reconnect: RuntimeReconnectOptions?
    public let heartbeat: RuntimeHeartbeatOptions?
    public let trafficMonitor: RuntimeTrafficMonitorOptions?

    public init(
        reconnect: RuntimeReconnectOptions? = nil,
        heartbeat: RuntimeHeartbeatOptions? = nil,
        trafficMonitor: RuntimeTrafficMonitorOptions? = nil
    ) {
        self.reconnect = reconnect
        self.heartbeat = heartbeat
        self.trafficMonitor = trafficMonitor
    }
}

public struct RuntimeServerObservabilityOptions: Sendable, Equatable {
    public let trafficMonitor: RuntimeTrafficMonitorOptions?

    public init(
        trafficMonitor: RuntimeTrafficMonitorOptions? = nil
    ) {
        self.trafficMonitor = trafficMonitor
    }
}

actor RequestSessionAllocator {
    private var nextValue: UInt16 = 1

    func nextSession() -> UInt16 {
        let session = nextValue
        nextValue &+= 1
        if nextValue == 0 {
            nextValue = 1
        }
        return session
    }
}

struct RequestKey: Hashable, Sendable {
    let session: UInt16

    init(session: UInt16) {
        self.session = session
    }
}

actor RequestCoordinator {
    private var continuations: [RequestKey: CheckedContinuation<ProtocolPacket, Error>] = [:]

    func register(_ key: RequestKey, continuation: CheckedContinuation<ProtocolPacket, Error>) {
        continuations[key] = continuation
    }

    func resolve(_ packet: ProtocolPacket) {
        let key = RequestKey(session: packet.header.session)
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(returning: packet)
    }

    func fail(_ key: RequestKey, error: Error) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(throwing: error)
    }

    func failAll(_ error: Error) {
        let values = continuations.values
        continuations.removeAll()

        for continuation in values {
            continuation.resume(throwing: error)
        }
    }
}
