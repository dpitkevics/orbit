import Foundation

/// How the user authenticates with an LLM provider.
public enum AuthMode: String, Codable, Sendable {
    case apiKey     // Direct API key
    case bridge     // Shell out to official CLI
    case oauth      // Direct OAuth PKCE flow
}

/// Resolved authentication credential for a provider.
public enum AuthCredential: Sendable {
    case apiKey(String)
    case bearer(String)
    case none
}

/// Configuration for authenticating with a specific provider.
public struct AuthConfig: Codable, Sendable {
    public let mode: AuthMode
    public let apiKeyEnv: String?
    public let apiKeyKeychain: String?
    public let cliPath: String?
    public let credentialsPath: String?

    public init(
        mode: AuthMode = .apiKey,
        apiKeyEnv: String? = nil,
        apiKeyKeychain: String? = nil,
        cliPath: String? = nil,
        credentialsPath: String? = nil
    ) {
        self.mode = mode
        self.apiKeyEnv = apiKeyEnv
        self.apiKeyKeychain = apiKeyKeychain
        self.cliPath = cliPath
        self.credentialsPath = credentialsPath
    }

    /// Resolve the API key from environment variables.
    public func resolveAPIKey() -> String? {
        guard mode == .apiKey else { return nil }

        if let envName = apiKeyEnv, let value = ProcessInfo.processInfo.environment[envName] {
            return value
        }

        // Fallback: try common env var names for the provider
        return nil
    }
}

/// Errors during authentication.
public enum AuthError: Error, LocalizedError {
    case missingAPIKey(provider: String, envVar: String?)
    case invalidCredentials(String)
    case unsupportedAuthMode(AuthMode)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider, let envVar):
            if let envVar {
                return "No API key found for \(provider). Set the \(envVar) environment variable."
            }
            return "No API key configured for \(provider)."
        case .invalidCredentials(let detail):
            return "Invalid credentials: \(detail)"
        case .unsupportedAuthMode(let mode):
            return "Auth mode '\(mode.rawValue)' is not yet supported."
        }
    }
}
