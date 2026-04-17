import EasyNet
import Foundation
import Darwin

@main
enum EasyNetTerminalClientDemoMain {
    static func main() async throws {
        configureStdoutForAutomation()
        let options = ClientCLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))

        let client = try EasyNetBuilder()
            .useTCPClient(host: options.host, port: options.port)
            .addPlugin(TerminalTextPlugin())
            .buildClient()

        let connectionSignal = AsyncSignal<Void>()
        let messageSignal = AsyncSignal<String>()

        Task {
            for await event in client.events {
                switch event {
                case .stateChanged(let state):
                    print("[client] state: \(state)")
                case .connected(let context):
                    print("[client] connected: \(context.remoteAddress ?? "unknown")")
                    await connectionSignal.fire(())
                case .disconnected(_, let reason):
                    print("[client] disconnected: \(reason)")
                case .packet(_, let packet):
                    print("[client] packet command=\(packet.header.command) magic=\(packet.header.magic)")
                case .message(_, let message):
                    if let text = message as? TerminalTextMessage {
                        print("[client] received: \(text.text)")
                        await messageSignal.fire(text.text)
                    }
                case .failure(let error):
                    print("[client] error: \(error)")
                }
            }
        }

        client.connect()

        print("EasyNet terminal client demo connected target: \(options.host):\(options.port)")

        if let autoMessage = options.autoMessage {
            print("Auto mode enabled, sending one message and waiting for response")
            try await connectionSignal.wait(timeoutSeconds: options.timeoutSeconds)
            let request = TerminalTextMessage(text: autoMessage, magic: .request, session: 1)
            try await client.send(message: request)
            let response = try await messageSignal.wait(timeoutSeconds: options.timeoutSeconds)
            print("[client] auto response confirmed: \(response)")
            client.disconnect()
            return
        }

        if !options.autoMessages.isEmpty {
            print("Batch auto mode enabled, sending \(options.autoMessages.count) messages")
            try await connectionSignal.wait(timeoutSeconds: options.timeoutSeconds)

            var session: UInt16 = 1
            for text in options.autoMessages {
                let request = TerminalTextMessage(text: text, magic: .request, session: session)
                try await client.send(message: request)
                let response = try await messageSignal.waitNext(timeoutSeconds: options.timeoutSeconds)
                print("[client] auto response confirmed: \(response)")
                session &+= 1
                if session == 0 {
                    session = 1
                }
            }

            client.disconnect()
            return
        }

        try await connectionSignal.wait(timeoutSeconds: options.timeoutSeconds)
        print("Type text and press Enter, type /quit to exit")

        var session: UInt16 = 1
        let inputStream = makeLineStream()
        for await line in inputStream {
            if line == "/quit" {
                break
            }
            if line.isEmpty {
                continue
            }
            let message = TerminalTextMessage(text: line, magic: .request, session: session)
            try await client.send(message: message)
            session &+= 1
            if session == 0 {
                session = 1
            }
        }

        client.disconnect()
    }
}

private struct ClientCLIOptions {
    let host: String
    let port: Int
    let autoMessage: String?
    let autoMessages: [String]
    let timeoutSeconds: TimeInterval

    init(arguments: [String]) {
        var positionals: [String] = []
        var autoMessage: String?
        var autoMessages: [String] = []
        var timeoutSeconds: TimeInterval = 5

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--message":
                if index + 1 < arguments.count {
                    autoMessage = arguments[index + 1]
                    index += 1
                }
            case "--messages":
                if index + 1 < arguments.count {
                    autoMessages = arguments[index + 1]
                        .split(separator: "|")
                        .map(String.init)
                    index += 1
                }
            case "--timeout":
                if index + 1 < arguments.count, let value = TimeInterval(arguments[index + 1]) {
                    timeoutSeconds = value
                    index += 1
                }
            default:
                positionals.append(argument)
            }
            index += 1
        }

        self.host = positionals.first ?? "127.0.0.1"
        self.port = Int(positionals.dropFirst().first ?? "") ?? 9999
        self.autoMessage = autoMessage
        self.autoMessages = autoMessages
        self.timeoutSeconds = timeoutSeconds
    }
}

private actor AsyncSignal<Value: Sendable> {
    private var values: [Value] = []

    func fire(_ newValue: Value) {
        values.append(newValue)
    }

    func wait(timeoutSeconds: TimeInterval) async throws -> Value {
        try await waitNext(timeoutSeconds: timeoutSeconds)
    }

    func waitNext(timeoutSeconds: TimeInterval) async throws -> Value {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !values.isEmpty {
                return values.removeFirst()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw DemoTimeoutError.timeout
    }
}

private enum DemoTimeoutError: Error {
    case timeout
}

private func configureStdoutForAutomation() {
    setbuf(__stdoutp, nil)
}

private func makeLineStream() -> AsyncStream<String> {
    AsyncStream { continuation in
        let queue = DispatchQueue(label: "easynet.terminal.stdin")
        queue.async {
            while let line = readLine() {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}
