import AuthenticationServices
import UIKit
import CryptoKit
import Foundation
import Security

// MARK: - Session persistence

struct Session: Codable {
    struct OAuth: Codable {
        let tokenEndpoint: URL
        let clientID: String
        let dpopKey: Data
    }
    let did: String
    let handle: String
    var accessJwt: String
    var refreshJwt: String
    let serviceEndpoint: String?
    let oauth: OAuth?
}

struct SessionStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "thimble",
         kSecAttrAccount as String: "s"]
    }

    func save(_ session: Session?) {
        SecItemDelete(query as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    func load() -> Session? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
}

// MARK: - DPoP

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct DPoPSigner {
    private struct JWK: Encodable {
        let kty = "EC"
        let crv = "P-256"
        let x: String
        let y: String
    }
    private struct Header: Encodable {
        let typ = "dpop+jwt"
        let alg = "ES256"
        let jwk: JWK
    }
    private struct Claims: Encodable {
        let htm: String
        let htu: String
        let iat: Int
        let jti: String
        let nonce: String?
        let ath: String?
    }

    private let key: P256.Signing.PrivateKey

    init() { key = P256.Signing.PrivateKey() }
    init(rawKey: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawKey) }

    var rawKey: Data { key.rawRepresentation }

    func proof(method: String, url: URL, accessToken: String?, nonce: String?) throws -> String {
        let point = key.publicKey.rawRepresentation
        let header = Header(jwk: JWK(x: point.prefix(32).base64URL, y: point.suffix(32).base64URL))
        let target = url.absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url.absoluteString
        let claims = Claims(
            htm: method,
            htu: target,
            iat: Int(Date.now.timeIntervalSince1970),
            jti: UUID().uuidString,
            nonce: nonce,
            ath: accessToken.map { Data(SHA256.hash(data: Data($0.utf8))).base64URL }
        )
        let encoder = JSONEncoder()
        let message = "\(try encoder.encode(header).base64URL).\(try encoder.encode(claims).base64URL)"
        let signature = try key.signature(for: Data(message.utf8))
        return "\(message).\(signature.rawRepresentation.base64URL)"
    }
}

// MARK: - OAuth

enum OAuthError: LocalizedError {
    case handleNotFound, serverNotFound, couldNotStart, cancelled, stateMismatch, failed

    var errorDescription: String? {
        switch self {
        case .handleNotFound: "Handle not found"
        case .serverNotFound: "Could not find your server"
        case .couldNotStart: "Sign-in could not start"
        case .cancelled: "Sign-in cancelled"
        case .stateMismatch: "Sign-in failed: state mismatch"
        case .failed: "Sign-in failed"
        }
    }
}

@MainActor
final class OAuthFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private struct ResolvedHandle: Decodable { let did: String }
    private struct DIDDocument: Decodable {
        struct Service: Decodable {
            let id: String
            let serviceEndpoint: String
        }
        let service: [Service]
    }
    private struct ProtectedResource: Decodable {
        let authorizationServers: [String]
        private enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers" }
    }
    private struct ServerMetadata: Decodable {
        let par: URL
        let authorization: String
        let token: URL
        private enum CodingKeys: String, CodingKey {
            case par = "pushed_authorization_request_endpoint"
            case authorization = "authorization_endpoint"
            case token = "token_endpoint"
        }
    }
    private struct PARResponse: Decodable {
        let requestURI: String
        private enum CodingKeys: String, CodingKey { case requestURI = "request_uri" }
    }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let sub: String
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", sub
        }
    }

    private static let scope = "atproto transition:generic transition:chat.bsky"
    private static let redirect = "http://127.0.0.1:8123/cb"

    /// A release client ID is the URL of the hosted metadata file. It is unset until that file is published.
    static var clientID: String? {
        guard ProcessInfo.processInfo.environment["THIMBLE_OAUTH_DEV"] != nil else { return nil }
        return "http://localhost?redirect_uri=\(redirect.formEncoded)&scope=\(scope.formEncoded)"
    }

    private let client: BlueskyClient
    private let anchor: UIWindow
    private var webSession: ASWebAuthenticationSession?

    init(client: BlueskyClient, anchor: UIWindow) {
        self.client = client
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    func signIn(handle: String) async throws {
        guard let clientID = Self.clientID else { throw OAuthError.couldNotStart }
        let did = try await resolve(handle)
        let pds = try await personalServer(for: did)
        let metadata = try await serverMetadata(for: pds)

        let signer = DPoPSigner()
        let verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let state = UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        let (parData, parStatus) = try await client.postForm(to: metadata.par, form: [
            ("client_id", clientID), ("response_type", "code"), ("redirect_uri", Self.redirect), ("scope", Self.scope),
            ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("login_hint", handle),
        ], signer: signer)
        guard parStatus == 201, let par = try? JSONDecoder().decode(PARResponse.self, from: parData),
              let url = URL(string: "\(metadata.authorization)?client_id=\(clientID.formEncoded)&request_uri=\(par.requestURI.formEncoded)")
        else { throw OAuthError.couldNotStart }

        let callback = try await authenticate(at: url)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw OAuthError.stateMismatch }
        let code = items.first { $0.name == "code" }?.value ?? ""

        let (tokenData, tokenStatus) = try await client.postForm(to: metadata.token, form: [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirect),
            ("client_id", clientID), ("code_verifier", verifier),
        ], signer: signer)
        guard tokenStatus == 200, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: tokenData), tokens.sub == did else {
            throw OAuthError.failed
        }
        client.adopt(Session(
            did: did, handle: handle, accessJwt: tokens.accessToken, refreshJwt: tokens.refreshToken, serviceEndpoint: pds,
            oauth: .init(tokenEndpoint: metadata.token, clientID: clientID, dpopKey: signer.rawKey)
        ))
    }

    private func resolve(_ handle: String) async throws -> String {
        var components = URLComponents(string: "https://bsky.social/xrpc/com.atproto.identity.resolveHandle")
        components?.queryItems = [URLQueryItem(name: "handle", value: handle)]
        guard let url = components?.url, let resolved: ResolvedHandle = try? await client.getJSON(url) else { throw OAuthError.handleNotFound }
        return resolved.did
    }

    private func personalServer(for did: String) async throws -> String {
        guard let url = URL(string: "https://plc.directory/\(did)"),
              let document: DIDDocument = try? await client.getJSON(url),
              let pds = document.service.first(where: { $0.id == "#atproto_pds" })?.serviceEndpoint
        else { throw OAuthError.serverNotFound }
        return pds
    }

    private func serverMetadata(for pds: String) async throws -> ServerMetadata {
        guard let resourceURL = URL(string: "\(pds)/.well-known/oauth-protected-resource") else { throw OAuthError.serverNotFound }
        let resource: ProtectedResource = try await client.getJSON(resourceURL)
        guard let server = resource.authorizationServers.first,
              let metadataURL = URL(string: "\(server)/.well-known/oauth-authorization-server")
        else { throw OAuthError.serverNotFound }
        return try await client.getJSON(metadataURL)
    }

    private func authenticate(at url: URL) async throws -> URL {
        defer { webSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "thimble") { callback, _ in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            webSession = session
            session.start()
        }
    }
}
