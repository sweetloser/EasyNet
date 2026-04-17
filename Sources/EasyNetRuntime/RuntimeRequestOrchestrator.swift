import Foundation
import EasyNetProtocolCore

actor RuntimeRequestOrchestrator {
    private let coordinator = RequestCoordinator()
    private let sessionAllocator = RequestSessionAllocator()
    private var timeoutTasks: [RequestKey: Task<Void, Never>] = [:]

    func request(
        _ packet: ProtocolPacket,
        options: RuntimeRequestOptions,
        send: @escaping @Sendable (ProtocolPacket) async throws -> Void
    ) async throws -> ProtocolPacket {
        let requestPacket = await prepareRequestPacket(packet)
        var attempt = 0

        while true {
            do {
                return try await requestOnce(requestPacket, timeout: options.timeout, send: send)
            } catch {
                guard shouldRetry(error, attempt: attempt, options: options) else {
                    throw error
                }
                attempt += 1
                try await sleepBeforeRetry(
                    backoff: options.retryBackoff,
                    jitter: options.retryJitter,
                    retryAttempt: attempt
                )
            }
        }
    }

    func resolveIfNeeded(_ packet: ProtocolPacket) async {
        guard packet.header.magic == .response else {
            return
        }

        let key = RequestKey(session: packet.header.session)
        timeoutTasks.removeValue(forKey: key)?.cancel()
        await coordinator.resolve(packet)
    }

    func failAll(_ error: Error) async {
        let tasks = timeoutTasks.values
        timeoutTasks.removeAll()

        for task in tasks {
            task.cancel()
        }

        await coordinator.failAll(error)
    }

    private func prepareRequestPacket(_ packet: ProtocolPacket) async -> ProtocolPacket {
        guard packet.header.magic == .request, packet.header.session == 0 else {
            return packet
        }

        var requestPacket = packet
        requestPacket.header.session = await sessionAllocator.nextSession()
        return requestPacket
    }

    private func requestOnce(
        _ packet: ProtocolPacket,
        timeout: TimeInterval?,
        send: @escaping @Sendable (ProtocolPacket) async throws -> Void
    ) async throws -> ProtocolPacket {
        let requestKey = RequestKey(session: packet.header.session)

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await coordinator.register(requestKey, continuation: continuation)
                installTimeoutTask(for: requestKey, timeout: timeout)

                do {
                    try await send(packet)
                } catch {
                    await fail(requestKey, error: error)
                }
            }
        }
    }

    private func installTimeoutTask(for key: RequestKey, timeout: TimeInterval?) {
        timeoutTasks.removeValue(forKey: key)?.cancel()

        guard let timeout, timeout > 0 else {
            return
        }

        timeoutTasks[key] = Task { [weak self] in
            let duration = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled, let self else {
                return
            }
            await self.fail(key, error: RuntimeRequestError.timeout(session: key.session))
        }
    }

    private func fail(_ key: RequestKey, error: Error) async {
        timeoutTasks.removeValue(forKey: key)?.cancel()
        await coordinator.fail(key, error: error)
    }

    private func shouldRetry(_ error: Error, attempt: Int, options: RuntimeRequestOptions) -> Bool {
        guard attempt < options.retryCount else {
            return false
        }

        switch options.retryCondition {
        case .allFailures:
            return true
        case .timeoutOnly:
            return (error as? RuntimeRequestError).map {
                if case .timeout = $0 { return true }
                return false
            } ?? false
        }
    }

    private func sleepBeforeRetry(
        backoff: RuntimeRetryBackoff,
        jitter: RuntimeRetryJitter,
        retryAttempt: Int
    ) async throws {
        let delay = backoff.delay(forRetryAttempt: retryAttempt, jitter: jitter)
        guard delay > 0 else {
            return
        }

        let duration = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: duration)
    }
}
