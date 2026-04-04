import Foundation
import Testing
@testable import OrbitCore

@Suite("Auth")
struct AuthTests {
    @Test("AuthMode raw values")
    func authModeRawValues() {
        #expect(AuthMode.apiKey.rawValue == "apiKey")
        #expect(AuthMode.bridge.rawValue == "bridge")
        #expect(AuthMode.oauth.rawValue == "oauth")
    }

    @Test("AuthConfig resolves API key from environment")
    func resolveAPIKeyFromEnv() {
        let envKey = "ORBIT_TEST_API_KEY_\(UUID().uuidString.prefix(8))"
        setenv(envKey, "test-key-123", 1)
        defer { unsetenv(envKey) }

        let config = AuthConfig(mode: .apiKey, apiKeyEnv: envKey)
        #expect(config.resolveAPIKey() == "test-key-123")
    }

    @Test("AuthConfig returns nil for missing env var")
    func resolveAPIKeyMissingEnv() {
        let config = AuthConfig(mode: .apiKey, apiKeyEnv: "ORBIT_NONEXISTENT_VAR_99999")
        #expect(config.resolveAPIKey() == nil)
    }

    @Test("AuthConfig returns nil for non-apiKey mode")
    func resolveAPIKeyWrongMode() {
        let config = AuthConfig(mode: .bridge, apiKeyEnv: "SOME_KEY")
        #expect(config.resolveAPIKey() == nil)
    }

    @Test("AuthConfig default initialization")
    func authConfigDefaults() {
        let config = AuthConfig()
        #expect(config.mode == .apiKey)
        #expect(config.apiKeyEnv == nil)
        #expect(config.apiKeyKeychain == nil)
        #expect(config.cliPath == nil)
        #expect(config.credentialsPath == nil)
    }

    @Test("AuthError descriptions")
    func authErrorDescriptions() {
        let err1 = AuthError.missingAPIKey(provider: "anthropic", envVar: "ANTHROPIC_API_KEY")
        #expect(err1.errorDescription?.contains("ANTHROPIC_API_KEY") == true)

        let err2 = AuthError.missingAPIKey(provider: "openai", envVar: nil)
        #expect(err2.errorDescription?.contains("openai") == true)

        let err3 = AuthError.invalidCredentials("bad token")
        #expect(err3.errorDescription?.contains("bad token") == true)

        let err4 = AuthError.unsupportedAuthMode(.oauth)
        #expect(err4.errorDescription?.contains("oauth") == true)
    }
}
