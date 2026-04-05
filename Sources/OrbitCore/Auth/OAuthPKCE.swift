import Foundation
import Crypto

/// PKCE code verifier/challenge pair for OAuth 2.0.
public struct PKCECodePair: Sendable {
    public let verifier: String
    public let challenge: String
    public let challengeMethod: String = "S256"

    /// Generate a new PKCE pair with cryptographically random verifier.
    public static func generate() -> PKCECodePair {
        let verifier = generateRandomBase64URL(byteCount: 32)
        let challenge = computeS256Challenge(verifier: verifier)
        return PKCECodePair(verifier: verifier, challenge: challenge)
    }

    private static func generateRandomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func computeS256Challenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

/// Stored OAuth token set.
public struct OAuthTokenSet: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// OAuth authorization request parameters.
public struct OAuthAuthorizationRequest: Sendable {
    public let authorizeURL: String
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]
    public let state: String
    public let codeChallenge: String
    public let codeChallengeMethod: String

    public init(
        authorizeURL: String,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        state: String,
        pkce: PKCECodePair
    ) {
        self.authorizeURL = authorizeURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.state = state
        self.codeChallenge = pkce.challenge
        self.codeChallengeMethod = pkce.challengeMethod
    }

    /// Build the full authorization URL with all parameters.
    public func buildURL() -> URL? {
        var components = URLComponents(string: authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod),
        ]
        return components?.url
    }
}

/// Manages OAuth PKCE authentication flow.
public struct OAuthManager: Sendable {
    private let credentialsPath: String

    public init(credentialsPath: String = "~/.orbit/credentials.json") {
        self.credentialsPath = (credentialsPath as NSString).expandingTildeInPath
    }

    /// Load stored OAuth credentials.
    public func loadCredentials() -> OAuthTokenSet? {
        guard let data = FileManager.default.contents(atPath: credentialsPath),
              let root = try? JSONDecoder().decode([String: OAuthTokenSet].self, from: data),
              let oauth = root["oauth"] else {
            return nil
        }
        return oauth
    }

    /// Save OAuth credentials.
    public func saveCredentials(_ tokenSet: OAuthTokenSet) throws {
        let dir = (credentialsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var root: [String: OAuthTokenSet] = [:]
        if let data = FileManager.default.contents(atPath: credentialsPath),
           let existing = try? JSONDecoder().decode([String: OAuthTokenSet].self, from: data) {
            root = existing
        }
        root["oauth"] = tokenSet

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(root)
        try data.write(to: URL(fileURLWithPath: credentialsPath))
    }

    /// Clear stored OAuth credentials.
    public func clearCredentials() throws {
        guard FileManager.default.fileExists(atPath: credentialsPath) else { return }
        var root: [String: OAuthTokenSet] = [:]
        if let data = FileManager.default.contents(atPath: credentialsPath),
           let existing = try? JSONDecoder().decode([String: OAuthTokenSet].self, from: data) {
            root = existing
        }
        root.removeValue(forKey: "oauth")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(root)
        try data.write(to: URL(fileURLWithPath: credentialsPath))
    }

    /// Try to load credentials from Claude Code's credential file.
    public static func loadFromClaudeCode() -> OAuthTokenSet? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudePath = home.appendingPathComponent(".claude/credentials.json").path
        guard let data = FileManager.default.contents(atPath: claudePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthObj = json["oauth"] as? [String: Any],
              let accessToken = oauthObj["accessToken"] as? String else {
            return nil
        }
        let refreshToken = oauthObj["refreshToken"] as? String
        let expiresAt: Date? = (oauthObj["expiresAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let scopes = oauthObj["scopes"] as? [String] ?? []

        return OAuthTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }

    /// Run the OAuth PKCE login flow: open browser, listen for callback, exchange code for token.
    public func login(
        authorizeURL: String,
        tokenURL: String,
        clientID: String,
        scopes: [String] = [],
        callbackPort: UInt16 = 9876
    ) async throws -> OAuthTokenSet {
        let pkce = PKCECodePair.generate()
        let state = PKCECodePair.generate().verifier // Random state

        let redirectURI = "http://localhost:\(callbackPort)/callback"
        let authRequest = OAuthAuthorizationRequest(
            authorizeURL: authorizeURL,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: scopes,
            state: state,
            pkce: pkce
        )

        guard let authURL = authRequest.buildURL() else {
            throw OAuthError.invalidURL
        }

        // Open browser
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [authURL.absoluteString]
        try process.run()
        process.waitUntilExit()

        print("Opening browser for authentication...")
        print("Waiting for callback on port \(callbackPort)...")

        // Listen for callback
        let callbackParams = try await listenForCallback(port: callbackPort, expectedState: state)

        guard let code = callbackParams.code else {
            if let error = callbackParams.error {
                throw OAuthError.authorizationDenied(error)
            }
            throw OAuthError.noAuthorizationCode
        }

        // Exchange code for token
        let tokenSet = try await exchangeCode(
            code: code,
            tokenURL: tokenURL,
            clientID: clientID,
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier
        )

        try saveCredentials(tokenSet)
        return tokenSet
    }

    // MARK: - Private

    private func listenForCallback(port: UInt16, expectedState: String) async throws -> CallbackParams {
        // Simple HTTP listener using raw sockets via Process + nc approach
        // For a production app, this would use NIO or Network.framework.
        // Using a file-based approach with a temporary HTTP server via Python.
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("orbit_oauth_\(port).py")
        let script = """
        import http.server, urllib.parse, json, sys

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                params = urllib.parse.parse_qs(parsed.query)
                result = {
                    "code": params.get("code", [None])[0],
                    "state": params.get("state", [None])[0],
                    "error": params.get("error", [None])[0],
                    "error_description": params.get("error_description", [None])[0]
                }
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(b"<html><body><h1>Authentication complete!</h1><p>You can close this window.</p></body></html>")
                with open(sys.argv[1], "w") as f:
                    json.dump(result, f)
                raise SystemExit(0)

            def log_message(self, format, *args): pass

        server = http.server.HTTPServer(("localhost", \(port)), Handler)
        server.handle_request()
        """

        let resultFile = FileManager.default.temporaryDirectory.appendingPathComponent("orbit_oauth_result_\(port).json")
        try script.write(to: tempScript, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tempScript.path, resultFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // Clean up script
        try? FileManager.default.removeItem(at: tempScript)

        guard let data = FileManager.default.contents(atPath: resultFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.callbackFailed
        }

        try? FileManager.default.removeItem(at: resultFile)

        let params = CallbackParams(
            code: json["code"] as? String,
            state: json["state"] as? String,
            error: json["error"] as? String,
            errorDescription: json["error_description"] as? String
        )

        if params.state != expectedState {
            throw OAuthError.stateMismatch
        }

        return params
    }

    private func exchangeCode(
        code: String,
        tokenURL: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> OAuthTokenSet {
        guard let url = URL(string: tokenURL) else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed(bodyStr)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError.tokenExchangeFailed("No access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval
        let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }

        return OAuthTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    private struct CallbackParams {
        let code: String?
        let state: String?
        let error: String?
        let errorDescription: String?
    }
}

public enum OAuthError: Error, LocalizedError {
    case invalidURL
    case authorizationDenied(String)
    case noAuthorizationCode
    case callbackFailed
    case stateMismatch
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid OAuth URL."
        case .authorizationDenied(let err): return "Authorization denied: \(err)"
        case .noAuthorizationCode: return "No authorization code received."
        case .callbackFailed: return "OAuth callback failed."
        case .stateMismatch: return "OAuth state mismatch (possible CSRF attack)."
        case .tokenExchangeFailed(let detail): return "Token exchange failed: \(detail)"
        case .tokenRefreshFailed(let detail): return "Token refresh failed: \(detail)"
        }
    }
}

// MARK: - Base64URL Encoding

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
