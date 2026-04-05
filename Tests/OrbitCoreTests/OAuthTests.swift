import Foundation
import Testing
@testable import OrbitCore

@Suite("OAuth PKCE")
struct OAuthTests {
    @Test("PKCECodePair generates valid verifier and challenge")
    func pkceGenerate() {
        let pair = PKCECodePair.generate()
        #expect(!pair.verifier.isEmpty)
        #expect(!pair.challenge.isEmpty)
        #expect(pair.challengeMethod == "S256")
        #expect(pair.verifier != pair.challenge)
    }

    @Test("PKCECodePair generates unique pairs")
    func pkceUnique() {
        let pair1 = PKCECodePair.generate()
        let pair2 = PKCECodePair.generate()
        #expect(pair1.verifier != pair2.verifier)
        #expect(pair1.challenge != pair2.challenge)
    }

    @Test("OAuthAuthorizationRequest builds valid URL")
    func authRequestURL() {
        let pkce = PKCECodePair.generate()
        let request = OAuthAuthorizationRequest(
            authorizeURL: "https://example.com/authorize",
            clientID: "test-client",
            redirectURI: "http://localhost:9876/callback",
            scopes: ["read", "write"],
            state: "random-state",
            pkce: pkce
        )

        let url = request.buildURL()
        #expect(url != nil)
        let urlStr = url!.absoluteString
        #expect(urlStr.contains("response_type=code"))
        #expect(urlStr.contains("client_id=test-client"))
        #expect(urlStr.contains("code_challenge_method=S256"))
        #expect(urlStr.contains("state=random-state"))
    }

    @Test("OAuthTokenSet expiry check")
    func tokenExpiry() {
        let expired = OAuthTokenSet(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(-60)
        )
        #expect(expired.isExpired)

        let valid = OAuthTokenSet(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(3600)
        )
        #expect(!valid.isExpired)

        let noExpiry = OAuthTokenSet(accessToken: "token")
        #expect(!noExpiry.isExpired)
    }

    @Test("OAuthManager save and load credentials")
    func credentialRoundtrip() throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-oauth-test-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("credentials.json").path

        let manager = OAuthManager(credentialsPath: tempPath)

        let tokenSet = OAuthTokenSet(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["read"]
        )

        try manager.saveCredentials(tokenSet)
        let loaded = manager.loadCredentials()

        #expect(loaded != nil)
        #expect(loaded?.accessToken == "test-access-token")
        #expect(loaded?.refreshToken == "test-refresh-token")
        #expect(loaded?.scopes == ["read"])
    }

    @Test("OAuthManager clear credentials")
    func credentialClear() throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-oauth-test-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("credentials.json").path

        let manager = OAuthManager(credentialsPath: tempPath)

        try manager.saveCredentials(OAuthTokenSet(accessToken: "test"))
        #expect(manager.loadCredentials() != nil)

        try manager.clearCredentials()
        #expect(manager.loadCredentials() == nil)
    }

    @Test("OAuthManager load from nonexistent file returns nil")
    func credentialMissing() {
        let manager = OAuthManager(credentialsPath: "/nonexistent/path/credentials.json")
        #expect(manager.loadCredentials() == nil)
    }

    @Test("OAuthError descriptions")
    func errorDescriptions() {
        let errors: [OAuthError] = [
            .invalidURL,
            .authorizationDenied("user said no"),
            .noAuthorizationCode,
            .callbackFailed,
            .stateMismatch,
            .tokenExchangeFailed("bad request"),
            .tokenRefreshFailed("expired"),
        ]
        for err in errors {
            #expect(err.errorDescription != nil)
        }
    }

    @Test("Base64URL encoding")
    func base64URLEncoding() {
        let data = Data([0xFF, 0xFE, 0xFD]) // Contains +, /, = in standard base64
        let encoded = data.base64URLEncoded()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }
}
