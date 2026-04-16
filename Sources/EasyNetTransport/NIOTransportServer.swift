import Foundation
import NIO
import NIOCore

public final class NIOTransportServer: TransportServer, @unchecked Sendable {
    public private(set) var state: ConnectionState = .idle
    public let events: AsyncStream<TransportEvent>

    private let configuration: TransportServerConfiguration
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation
    private let bossGroup: EventLoopGroup
    private let workerGroup: EventLoopGroup
    private var serverChannel: Channel?
    private var childChannels: [ConnectionID: Channel] = [:]
    private var channelLookup: [ObjectIdentifier: ConnectionContext] = [:]
    private let lock = NSLock()

    public init(configuration: TransportServerConfiguration) {
        self.configuration = configuration
        self.bossGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.workerGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        stop()
        eventContinuation.finish()
    }

    public func start() async throws {
        guard state == .idle || state == .disconnected || state == .failed else {
            return
        }

        state = .connecting
        eventContinuation.yield(.connecting)

        let bootstrap = ServerBootstrap(group: bossGroup, childGroup: workerGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
                return channel.pipeline.addHandler(ServerInboundHandler(owner: self))
            }

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        serverChannel = channel
        state = .connected
        let context = ConnectionContext(
            id: ConnectionID(),
            localAddress: channel.localAddress.map(Self.stringifyAddress),
            remoteAddress: nil
        )
        eventContinuation.yield(.connected(context))
    }

    public func stop() {
        guard state == .connecting || state == .connected else {
            return
        }

        state = .disconnecting
        serverChannel?.close(promise: nil)
        serverChannel = nil
        state = .disconnected
        eventContinuation.yield(.disconnected(nil, .localClosed))
        lock.lock()
        childChannels.removeAll()
        channelLookup.removeAll()
        lock.unlock()

        try? bossGroup.syncShutdownGracefully()
        try? workerGroup.syncShutdownGracefully()
    }

    public func send(_ buffer: ByteBuffer, to connectionID: ConnectionID) async throws {
        let channel = lock.withLock { childChannels[connectionID] }
        guard let channel else {
            throw ConnectionCloseReason.transportError("connection_not_found")
        }
        try await channel.writeAndFlush(buffer).get()
    }

    fileprivate func handleAcceptedConnection(_ channel: Channel) {
        let connectionID = ConnectionID()
        let context = ConnectionContext(
            id: connectionID,
            localAddress: channel.localAddress.map(Self.stringifyAddress),
            remoteAddress: channel.remoteAddress.map(Self.stringifyAddress)
        )
        lock.lock()
        childChannels[connectionID] = channel
        channelLookup[ObjectIdentifier(channel)] = context
        lock.unlock()
        eventContinuation.yield(.connected(context))
    }

    fileprivate func handleInbound(_ buffer: ByteBuffer, channel: Channel) {
        let context = lock.withLock { channelLookup[ObjectIdentifier(channel)] }
        guard let context else { return }
        eventContinuation.yield(.inboundBytes(context, buffer))
    }

    fileprivate func handleDisconnected(_ reason: ConnectionCloseReason, channel: Channel) {
        lock.lock()
        let context = channelLookup.removeValue(forKey: ObjectIdentifier(channel))
        if let context {
            childChannels.removeValue(forKey: context.id)
        }
        lock.unlock()
        eventContinuation.yield(.disconnected(context, reason))
    }

    fileprivate func handleError(_ error: Error) {
        state = .failed
        eventContinuation.yield(.failed(error))
    }

    private static func stringifyAddress(_ address: SocketAddress) -> String {
        if let ip = address.ipAddress, let port = address.port {
            return "\(ip):\(port)"
        }
        return "\(address)"
    }
}

private final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var owner: NIOTransportServer?

    init(owner: NIOTransportServer) {
        self.owner = owner
    }

    func channelActive(context: ChannelHandlerContext) {
        owner?.handleAcceptedConnection(context.channel)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        owner?.handleInbound(unwrapInboundIn(data), channel: context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.handleDisconnected(.remoteClosed, channel: context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.handleError(error)
        context.close(promise: nil)
    }
}
