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
    private var pluginRegistrations: [PluginRegistration] = []

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
        pluginRegistrations.append(.instance(plugin))
        return self
    }

    @discardableResult
    public func addPluginFactory(_ makePlugin: @escaping () -> any ProtocolPlugin) -> EasyNetBuilder {
        pluginRegistrations.append(.factory(makePlugin))
        return self
    }

    public func buildClient() throws -> EasyNetClient {
        guard let configuration = clientConfiguration else {
            throw EasyNetBuilderError.missingClientConfiguration
        }
        let transport = NIOTransportClient(configuration: configuration)
        let runtime = EasyNetRuntimeClient(transport: transport, codec: codec, registry: makeRegistrySnapshot())
        return EasyNetClient(runtime: runtime)
    }

    public func buildServer() throws -> EasyNetServer {
        guard let configuration = serverConfiguration else {
            throw EasyNetBuilderError.missingServerConfiguration
        }
        let transport = NIOTransportServer(configuration: configuration)
        let runtime = EasyNetRuntimeServer(transport: transport, codec: codec, registry: makeRegistrySnapshot())
        return EasyNetServer(runtime: runtime)
    }

    private func makeRegistrySnapshot() -> DefaultPluginRegistry {
        let registry = DefaultPluginRegistry()
        for registration in pluginRegistrations {
            registry.install(registration.makePlugin())
        }
        return registry
    }
}

private enum PluginRegistration {
    case instance(any ProtocolPlugin)
    case factory(() -> any ProtocolPlugin)

    func makePlugin() -> any ProtocolPlugin {
        switch self {
        case .instance(let plugin):
            return plugin
        case .factory(let makePlugin):
            return makePlugin()
        }
    }
}

public enum EasyNetBuilderError: Error, Equatable {
    case missingClientConfiguration
    case missingServerConfiguration
}

public final class EasyNetClient: @unchecked Sendable {
    public let events: AsyncStream<RuntimeEvent>

    private let runtime: EasyNetRuntimeClient

    init(runtime: EasyNetRuntimeClient) {
        self.runtime = runtime
        self.events = runtime.events
    }

    public func start() {
        runtime.start()
    }

    public func stop() {
        runtime.stop()
    }

    public func connect() {
        start()
    }

    public func disconnect() {
        stop()
    }

    public func enableAutoReconnect(_ options: RuntimeReconnectOptions) {
        runtime.enableAutoReconnect(options)
    }

    public func disableAutoReconnect() {
        runtime.disableAutoReconnect()
    }

    public func enableHeartbeat(_ options: RuntimeHeartbeatOptions) {
        runtime.enableHeartbeat(options)
    }

    public func disableHeartbeat() {
        runtime.disableHeartbeat()
    }

    public func enableTrafficMonitor(_ options: RuntimeTrafficMonitorOptions) {
        runtime.enableTrafficMonitor(options)
    }

    public func disableTrafficMonitor() {
        runtime.disableTrafficMonitor()
    }

    public func configureObservability(_ options: RuntimeClientObservabilityOptions) {
        if let reconnect = options.reconnect {
            enableAutoReconnect(reconnect)
        } else {
            disableAutoReconnect()
        }

        if let heartbeat = options.heartbeat {
            enableHeartbeat(heartbeat)
        } else {
            disableHeartbeat()
        }

        if let trafficMonitor = options.trafficMonitor {
            enableTrafficMonitor(trafficMonitor)
        } else {
            disableTrafficMonitor()
        }
    }

    public func disableObservability() {
        disableAutoReconnect()
        disableHeartbeat()
        disableTrafficMonitor()
    }

    public func send(packet: ProtocolPacket) async throws {
        try await runtime.send(packet: packet)
    }

    public func send(message: any DomainMessage) async throws {
        try await runtime.send(message: message)
    }

    public func request(packet: ProtocolPacket) async throws -> ProtocolPacket {
        try await runtime.request(packet)
    }

    public func request(packet: ProtocolPacket, timeout: TimeInterval?) async throws -> ProtocolPacket {
        try await runtime.request(packet, timeout: timeout)
    }

    public func request(packet: ProtocolPacket, options: RuntimeRequestOptions) async throws -> ProtocolPacket {
        try await runtime.request(packet, options: options)
    }

    public func request(_ packet: ProtocolPacket) async throws -> ProtocolPacket {
        try await request(packet: packet)
    }

    public func request(_ packet: ProtocolPacket, timeout: TimeInterval?) async throws -> ProtocolPacket {
        try await request(packet: packet, timeout: timeout)
    }

    public func request(_ packet: ProtocolPacket, options: RuntimeRequestOptions) async throws -> ProtocolPacket {
        try await request(packet: packet, options: options)
    }

    public func request(message: any DomainMessage) async throws -> ProtocolPacket {
        try await runtime.request(message: message)
    }

    public func request(message: any DomainMessage, timeout: TimeInterval?) async throws -> ProtocolPacket {
        try await runtime.request(message: message, timeout: timeout)
    }

    public func request(message: any DomainMessage, options: RuntimeRequestOptions) async throws -> ProtocolPacket {
        try await runtime.request(message: message, options: options)
    }

    public func request<Response: DomainMessage>(
        message: any DomainMessage,
        as responseType: Response.Type,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        try await runtime.request(message: message, as: responseType, timeout: timeout)
    }

    public func request<Response: DomainMessage>(
        message: any DomainMessage,
        as responseType: Response.Type,
        options: RuntimeRequestOptions
    ) async throws -> Response {
        try await runtime.request(message: message, as: responseType, options: options)
    }
}

public final class EasyNetServer: @unchecked Sendable {
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

    public func enableTrafficMonitor(_ options: RuntimeTrafficMonitorOptions) {
        runtime.enableTrafficMonitor(options)
    }

    public func disableTrafficMonitor() {
        runtime.disableTrafficMonitor()
    }

    public func configureObservability(_ options: RuntimeServerObservabilityOptions) {
        if let trafficMonitor = options.trafficMonitor {
            enableTrafficMonitor(trafficMonitor)
        } else {
            disableTrafficMonitor()
        }
    }

    public func disableObservability() {
        disableTrafficMonitor()
    }

    public func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await runtime.send(packet: packet, to: connectionID)
    }

    public func send(message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await runtime.send(message: message, to: connectionID)
    }

    public func send(_ packet: ProtocolPacket, to connectionID: ConnectionID) async throws {
        try await send(packet: packet, to: connectionID)
    }

    public func send(_ message: any DomainMessage, to connectionID: ConnectionID) async throws {
        try await send(message: message, to: connectionID)
    }
}
