import Foundation
import NIO
import NIOCore

public final class NIOTransportClient: TransportClient, @unchecked Sendable {
    public private(set) var state: ConnectionState = .idle
    public let events: AsyncStream<TransportEvent>

    private let configuration: TransportClientConfiguration
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation
    private let group: EventLoopGroup
    private var channel: Channel?
    private var connectionContext: ConnectionContext?

    public init(configuration: TransportClientConfiguration) {
        self.configuration = configuration
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let stream = AsyncStream<TransportEvent>.makeStream()
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        stop()
        eventContinuation.finish()
    }

    public func start() {
        guard state == .idle || state == .disconnected || state == .failed else {
            return
        }

        state = .connecting
        eventContinuation.yield(.connecting)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
                return channel.pipeline.addHandler(ClientInboundHandler(owner: self))
            }

        bootstrap.connect(host: configuration.host, port: configuration.port).whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let channel):
                self.channel = channel
                let context = ConnectionContext(
                    id: ConnectionID(),
                    localAddress: channel.localAddress.map(Self.stringifyAddress),
                    remoteAddress: channel.remoteAddress.map(Self.stringifyAddress)
                )
                self.connectionContext = context
                self.state = .connected
                self.eventContinuation.yield(.connected(context))
            case .failure(let error):
                self.state = .failed
                self.eventContinuation.yield(.failed(error))
            }
        }
    }

    public func stop() {
        guard state == .connecting || state == .connected else {
            return
        }

        state = .disconnecting
        channel?.close(mode: .all, promise: nil)
        channel = nil
        state = .disconnected
        eventContinuation.yield(.disconnected(connectionContext, .localClosed))
        connectionContext = nil

        try? group.syncShutdownGracefully()
    }

    public func send(_ buffer: ByteBuffer) async throws {
        guard let channel else {
            throw ConnectionCloseReason.transportError("channel_not_ready")
        }

        try await channel.writeAndFlush(buffer).get()
    }

    fileprivate func handleInbound(_ buffer: ByteBuffer) {
        guard let connectionContext else { return }
        eventContinuation.yield(.inboundBytes(connectionContext, buffer))
    }

    fileprivate func handleDisconnected(_ reason: ConnectionCloseReason) {
        state = .disconnected
        eventContinuation.yield(.disconnected(connectionContext, reason))
        connectionContext = nil
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

private final class ClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var owner: NIOTransportClient?

    init(owner: NIOTransportClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        owner?.handleInbound(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.handleDisconnected(.remoteClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.handleError(error)
        context.close(promise: nil)
    }
}
