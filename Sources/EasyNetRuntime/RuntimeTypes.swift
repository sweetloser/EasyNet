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

    func delay(
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

public actor RequestSessionAllocator {
    private var nextValue: UInt16 = 1

    public init() {}

    public func nextSession() -> UInt16 {
        let session = nextValue
        nextValue &+= 1
        if nextValue == 0 {
            nextValue = 1
        }
        return session
    }
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

    public func fail(_ key: RequestKey, error: Error) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(throwing: error)
    }

    public func failAll(_ error: Error) {
        let values = continuations.values
        continuations.removeAll()

        for continuation in values {
            continuation.resume(throwing: error)
        }
    }
}
