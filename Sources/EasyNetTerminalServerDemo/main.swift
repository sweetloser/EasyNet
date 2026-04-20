import EasyNet
import Foundation
import Darwin

@main
enum EasyNetTerminalServerDemoMain {
    static func main() async throws {
        configureStdoutForAutomation()
        let port = parsePort(from: CommandLine.arguments.dropFirst().first) ?? 9999

        let server = try EasyNetBuilder()
            .useTCPServer(host: "127.0.0.1", port: port)
            .addPlugin(TerminalTextPlugin())
            .addPlugin(DemoChatPlugin())
            .buildServer()

        server.enableTrafficMonitor(RuntimeTrafficMonitorOptions(interval: 1))
        Task {
            for await event in server.events {
                switch event {
                case .stateChanged(let state):
                    print("[server] state: \(state)")
                case .connected(let context):
                    if let remote = context.remoteAddress {
                        print("[server] client connected: \(remote)")
                    } else {
                        print("[server] listening on \(context.localAddress ?? "unknown")")
                    }
                case .disconnected(let context, let reason):
                    print("[server] disconnected: \(context?.remoteAddress ?? context?.localAddress ?? "unknown"), reason: \(reason)")
                case .packet(_, let packet):
                    print("[server] packet command=\(packet.header.command) magic=\(packet.header.magic)")
                case .message(let context, let message):
                    if let text = message as? TerminalTextMessage {
                        print("[server] message from \(context?.remoteAddress ?? "unknown"): \(text.text)")
                    } else if let custom = message as? DemoChatMessage {
                        print(
                            "[server] custom message from \(context?.remoteAddress ?? "unknown") " +
                            "room=\(custom.room): \(custom.text)"
                        )
                    }
                case .traffic(_, let stats):
                    print("[server] traffic read=\(String(format: "%.2f", stats.readKBps))KB/s write=\(String(format: "%.2f", stats.writeKBps))KB/s")
                case .failure(let error):
                    print("[server] error: \(error)")
                }
            }
        }

        print("EasyNet terminal server demo starting at 127.0.0.1:\(port)")
        print("Press Ctrl+C to stop")

        try await server.start()
        await waitForever()
    }
}

private func parsePort(from value: String?) -> Int? {
    guard let value else { return nil }
    return Int(value)
}

private func waitForever() async {
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
}

private func configureStdoutForAutomation() {
    setbuf(__stdoutp, nil)
}
