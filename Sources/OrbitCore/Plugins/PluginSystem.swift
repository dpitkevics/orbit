import Foundation

/// Protocol for Orbit plugins. Plugins can provide tools, commands, and context.
public protocol OrbitPlugin: Sendable {
    /// Unique plugin identifier.
    var id: String { get }
    /// Human-readable name.
    var name: String { get }
    /// Plugin version.
    var version: String { get }

    /// Tools provided by this plugin.
    func tools() -> [any Tool]

    /// Called when the plugin is loaded.
    func onLoad() async throws
    /// Called when the plugin is unloaded.
    func onUnload() async throws
}

/// Default implementations.
extension OrbitPlugin {
    public func tools() -> [any Tool] { [] }
    public func onLoad() async throws {}
    public func onUnload() async throws {}
}

/// Manages plugin discovery and lifecycle.
public actor PluginManager {
    private var plugins: [String: any OrbitPlugin] = [:]

    public init() {}

    /// Register a plugin.
    public func register(_ plugin: any OrbitPlugin) async throws {
        guard plugins[plugin.id] == nil else {
            throw PluginError.alreadyRegistered(plugin.id)
        }
        try await plugin.onLoad()
        plugins[plugin.id] = plugin
    }

    /// Unregister a plugin.
    public func unregister(id: String) async throws {
        guard let plugin = plugins.removeValue(forKey: id) else {
            throw PluginError.notFound(id)
        }
        try await plugin.onUnload()
    }

    /// Get all registered plugins.
    public func allPlugins() -> [any OrbitPlugin] {
        Array(plugins.values)
    }

    /// Collect tools from all plugins.
    public func allTools() -> [any Tool] {
        plugins.values.flatMap { $0.tools() }
    }

    /// Get a plugin by ID.
    public func plugin(id: String) -> (any OrbitPlugin)? {
        plugins[id]
    }
}

public enum PluginError: Error, LocalizedError {
    case alreadyRegistered(String)
    case notFound(String)
    case loadFailed(String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .alreadyRegistered(let id):
            return "Plugin '\(id)' is already registered."
        case .notFound(let id):
            return "Plugin '\(id)' not found."
        case .loadFailed(let id, let error):
            return "Plugin '\(id)' failed to load: \(error)"
        }
    }
}
