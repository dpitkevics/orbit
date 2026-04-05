import Foundation
import OrbitCore

/// Shared provider resolution logic for all CLI commands.
func resolveProviderForChat(
    providerName: String,
    model: String,
    authModeOverride: String?,
    globalConfig: OrbitConfig
) throws -> any LLMProvider {
    let authConfig = globalConfig.auth[providerName]
    let resolvedMode: AuthMode

    if let override = authModeOverride {
        guard let mode = AuthMode(rawValue: override) else {
            throw AuthError.unsupportedAuthMode(.bridge)
        }
        resolvedMode = mode
    } else if let configured = authConfig?.mode {
        resolvedMode = configured
    } else {
        resolvedMode = autoDetectAuthMode(provider: providerName, authConfig: authConfig)
    }

    switch resolvedMode {
    case .apiKey:
        let apiKey = try resolveAPIKey(provider: providerName, authConfig: authConfig)
        switch providerName {
        case "openai":
            return OpenAIProvider(apiKey: apiKey, model: model)
        default:
            return AnthropicProvider(apiKey: apiKey, model: model)
        }

    case .bridge:
        let cliPath = try resolveCLIPath(provider: providerName, authConfig: authConfig)
        return BridgeProvider(name: providerName, cliPath: cliPath, model: model)

    case .oauth:
        let token = try resolveOAuthToken(provider: providerName, authConfig: authConfig)
        return AnthropicProvider(apiKey: token, model: model)
    }
}

private func autoDetectAuthMode(provider: String, authConfig: AuthConfig?) -> AuthMode {
    if authConfig?.resolveAPIKey() != nil {
        return .apiKey
    }

    let envVarName: String = switch provider {
    case "anthropic": "ANTHROPIC_API_KEY"
    case "openai": "OPENAI_API_KEY"
    default: "\(provider.uppercased())_API_KEY"
    }

    if ProcessInfo.processInfo.environment[envVarName] != nil {
        return .apiKey
    }

    if let cliPath = authConfig?.cliPath,
       FileManager.default.isExecutableFile(atPath: cliPath) {
        return .bridge
    }

    if provider == "anthropic", BridgeProvider.detectClaudeCLI() != nil {
        return .bridge
    }

    return .apiKey
}

private func resolveAPIKey(provider: String, authConfig: AuthConfig?) throws -> String {
    if let key = authConfig?.resolveAPIKey() {
        return key
    }

    let envVarName: String = switch provider {
    case "anthropic": "ANTHROPIC_API_KEY"
    case "openai": "OPENAI_API_KEY"
    default: "\(provider.uppercased())_API_KEY"
    }

    if let key = ProcessInfo.processInfo.environment[envVarName] {
        return key
    }

    throw AuthError.missingAPIKey(provider: provider, envVar: envVarName)
}

private func resolveCLIPath(provider: String, authConfig: AuthConfig?) throws -> String {
    if let path = authConfig?.cliPath,
       FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    if provider == "anthropic", let path = BridgeProvider.detectClaudeCLI() {
        return path
    }

    throw ProviderError.authenticationFailed(
        "No CLI tool found for '\(provider)'. Install the CLI or set cli_path in config."
    )
}

private func resolveOAuthToken(provider: String, authConfig: AuthConfig?) throws -> String {
    // Try loading from Orbit's credential store
    let credPath = authConfig?.credentialsPath ?? "~/.orbit/credentials.json"
    let manager = OAuthManager(credentialsPath: credPath)

    if let tokenSet = manager.loadCredentials(), !tokenSet.isExpired {
        return tokenSet.accessToken
    }

    // Try loading from Claude Code's credentials
    if provider == "anthropic", let tokenSet = OAuthManager.loadFromClaudeCode(), !tokenSet.isExpired {
        // Cache it in Orbit's store
        try? manager.saveCredentials(tokenSet)
        return tokenSet.accessToken
    }

    throw AuthError.invalidCredentials(
        "No valid OAuth token found. Run `orbit auth login` to authenticate."
    )
}
