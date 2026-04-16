@_exported import EasyNetPlugins
@_exported import EasyNetProtocolCore
@_exported import EasyNetProtocolPlugin
@_exported import EasyNetRuntime
@_exported import EasyNetTransport

import Foundation

public final class EasyNetBuilder {
    private var clientConfiguration: TransportClientConfiguration?
    private var serverConfiguration: TransportServerConfiguration?
    private var codec: any PacketCodec = EasyNetPacketCodec()
    private let registry = DefaultPluginRegistry()

    public init() {}

    @discardableResult
    public func useTCPClient(host: String, port: Int, timeoutSeconds: Int64 = 10) -> EasyNetBuilder {
        clientConfiguration = TransportClientConfiguration(host: host, port: port, connectTimeoutSeconds: timeoutSeconds)
        return self
    }

    @discardableResult
    public func useTCPServer(host: String, port: Int) -> EasyNetBuilder {
        serverConfiguration = TransportServerConfiguration(host: host, port: port)
        return self
    }

    @discardableResult
    public func useProtocol(_ codec: any PacketCodec) -> EasyNetBuilder {
        self.codec = codec
        return self
    }

    @discardableResult
    public func addPlugin(_ plugin: any ProtocolPlugin) -> EasyNetBuilder {
        registry.install(plugin)
        return self
    }

    public func buildClient() throws -> EasyNetClient {
        guard let configuration = clientConfiguration else {
            throw EasyNetBuilderError.missingClientConfiguration
        }
        let transport = NIOTransportClient(configuration: configuration)
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: registry)
        return EasyNetClient(runtime: runtime)
    }

    public func buildServer() throws -> EasyNetServer {
        guard let configuration = serverConfiguration else {
            throw EasyNetBuilderError.missingServerConfiguration
        }
        let transport = NIOTransportServer(configuration: configuration)
        let runtime = EasyNetRuntimeServer(transport: transport, codec: codec, registry: registry)
        return EasyNetServer(runtime: runtime)
    }
}

public enum EasyNetBuilderError: Error, Equatable {
    case missingClientConfiguration
    case missingServerConfiguration
}

public final class EasyNetClient {
    public let events: AsyncStream<RuntimeEvent>

    private let runtime: EasyNetRuntimeClient

    init(runtime: EasyNetRuntimeClient) {
        self.runtime = runtime
        self.events = runtime.events
    }

    public func connect() {
        runtime.start()
    }

    public func disconnect() {
        runtime.stop()
    }

    public func send(packet: ProtocolPacket) async throws {
        try await runtime.send(packet: packet)
    }

    public func send(message: any DomainMessage) async throws {
        try await runtime.send(message: message)
    }

    public func request(_ packet: ProtocolPacket) async throws -> ProtocolPacket {
        try await runtime.request(packet)
    }
}

public final class EasyNetServer {
    public let events: AsyncStream<RuntimeEvent>

    private let runtime: EasyNetRuntimeServer

    init(runtime: EasyNetRuntimeServer) {
        self.runtime = runtime
        self.events = runtime.events
    }

    public func start() async throws {
        try await runtime.start()
    }

    public func stop() {
        runtime.stop()
    }

    public func send(_ packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await runtime.send(packet: packet, to: connectionID)
    }

    public func send(_ message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await runtime.send(message: message, to: connectionID)
    }
}
