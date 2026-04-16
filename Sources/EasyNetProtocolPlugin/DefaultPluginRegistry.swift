import Foundation
import EasyNetProtocolCore
import EasyNetTransport

public final class DefaultPluginRegistry: PluginRegistry {
    private var plugins: [any ProtocolPlugin] = []
    private var mappers: [any PacketMapper] = []
    private var handlers: [any PacketRouteHandler] = []
    private var lifecycleHooks: [any PluginLifecycleHook] = []

    public init() {}

    public func install(_ plugin: any ProtocolPlugin) {
        plugins.append(plugin)
        plugin.setup(in: self)
    }

    public func register(mapper: any PacketMapper) {
        mappers.append(mapper)
    }

    public func register(handler: any PacketRouteHandler) {
        handlers.append(handler)
    }

    public func register(lifecycle: any PluginLifecycleHook) {
        lifecycleHooks.append(lifecycle)
    }

    public func decode(_ packet: ProtocolPacket) throws -> (any DomainMessage)? {
        for mapper in mappers {
            if let message = try mapper.decode(packet) {
                return message
            }
        }
        return nil
    }

    public func encode(_ message: any DomainMessage) throws -> ProtocolPacket {
        for mapper in mappers {
            if let packet = try mapper.encode(message) {
                return packet
            }
        }
        throw PluginRegistryError.missingMapper
    }

    public func matchingHandlers(for packet: ProtocolPacket) -> [any PacketRouteHandler] {
        handlers.filter { $0.canHandle(packet) }
    }

    public func notifyConnected(context: PluginContext) async {
        for hook in lifecycleHooks {
            await hook.didConnect(context: context)
        }
    }

    public func notifyDisconnected(reason: ConnectionCloseReason?, context: PluginContext) async {
        for hook in lifecycleHooks {
            await hook.didDisconnect(reason: reason, context: context)
        }
    }
}

public enum PluginRegistryError: Error {
    case missingMapper
}
