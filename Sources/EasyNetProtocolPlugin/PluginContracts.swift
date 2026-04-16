import Foundation
import EasyNetProtocolCore
import EasyNetTransport

public protocol DomainMessage: Sendable {}

public protocol ProtocolPlugin: AnyObject {
    var key: String { get }
    func setup(in registry: PluginRegistry)
}

public protocol PacketMapper: AnyObject {
    func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)?
    func encode(_ message: any DomainMessage) throws -> ProtocolPacket?
}

public protocol PacketRouteHandler: AnyObject {
    func canHandle(_ packet: ProtocolPacket) -> Bool
    func handle(_ packet: ProtocolPacket, context: PluginContext) async throws
}

public protocol PluginLifecycleHook: AnyObject {
    func didConnect(context: PluginContext) async
    func didDisconnect(reason: ConnectionCloseReason?, context: PluginContext) async
}

public extension PluginLifecycleHook {
    func didConnect(context: PluginContext) async {}
    func didDisconnect(reason: ConnectionCloseReason?, context: PluginContext) async {}
}

public protocol PluginContext: AnyObject {
    var connectionContext: ConnectionContext? { get }

    func send(packet: ProtocolPacket) async throws
    func send(message: any DomainMessage) async throws
    func send(packet: ProtocolPacket, to connectionID: ConnectionID) async throws
    func send(message: any DomainMessage, to connectionID: ConnectionID) async throws
}

public protocol PluginRegistry: AnyObject {
    func register(mapper: any PacketMapper)
    func register(handler: any PacketRouteHandler)
    func register(lifecycle: any PluginLifecycleHook)
}
