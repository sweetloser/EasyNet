import Foundation
import EasyNetTransport

actor RuntimeTrafficMonitor {
    private let emit: @Sendable (ConnectionContext?, RuntimeTrafficStats) -> Void

    private var options: RuntimeTrafficMonitorOptions?
    private var task: Task<Void, Never>?
    private var connectionContext: ConnectionContext?
    private var currentReadBytes = 0
    private var currentWriteBytes = 0
    private var cumulativeReadBytes = 0
    private var cumulativeWriteBytes = 0

    init(emit: @escaping @Sendable (ConnectionContext?, RuntimeTrafficStats) -> Void) {
        self.emit = emit
    }

    func enable(_ options: RuntimeTrafficMonitorOptions, connectionContext: ConnectionContext?) {
        self.options = options
        self.connectionContext = connectionContext
        startIfNeeded()
    }

    func disable() {
        options = nil
        task?.cancel()
        task = nil
    }

    func connected(_ connectionContext: ConnectionContext) {
        self.connectionContext = connectionContext
        startIfNeeded()
    }

    func disconnected() {
        connectionContext = nil
        task?.cancel()
        task = nil
    }

    func recordRead(_ bytes: Int) {
        currentReadBytes += bytes
        cumulativeReadBytes += bytes
    }

    func recordWrite(_ bytes: Int) {
        currentWriteBytes += bytes
        cumulativeWriteBytes += bytes
    }

    private func startIfNeeded() {
        guard task == nil, let options, options.interval > 0 else {
            return
        }

        task = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let nanoseconds = UInt64(options.interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self.emitSnapshot(interval: options.interval)
            }
        }
    }

    private func emitSnapshot(interval: TimeInterval) {
        let divisor = max(interval, 1)
        let stats = RuntimeTrafficStats(
            readKBps: (Double(currentReadBytes) / 1024.0) / divisor,
            writeKBps: (Double(currentWriteBytes) / 1024.0) / divisor,
            totalReadKB: Double(cumulativeReadBytes) / 1024.0,
            totalWriteKB: Double(cumulativeWriteBytes) / 1024.0
        )

        currentReadBytes = 0
        currentWriteBytes = 0
        emit(connectionContext, stats)
    }
}
