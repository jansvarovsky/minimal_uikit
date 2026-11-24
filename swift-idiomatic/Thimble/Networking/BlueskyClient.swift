import Foundation

enum APIError: LocalizedError {
    case http(status: Int, code: String?, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(_, _, let message): message
        case .invalidResponse: nil
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String?
    let message: String?
}

private struct CreateSessionRequest: Encodable {
    let identifier: String
    let password: String
}

private struct ServerSession: Decodable {
    struct DIDDocument: Decodable {
        struct Service: Decodable {
            let serviceEndpoint: String
        }
        let service: [Service]?
    }
    let did: String
    let handle: String
    let accessJwt: String
    let refreshJwt: String
    let didDoc: DIDDocument?
}

private struct OAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
    }
}

@MainActor
final class BlueskyClient {
    private(set) var session: Session?
    private let store = SessionStore()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var nonces: [String: String] = [:]

    init() {
        session = store.load()
    }

    var did: String? { session?.did }
    private var baseURL: String { (session?.serviceEndpoint ?? "https://bsky.social") + "/xrpc/" }

    // MARK: Session

    func adopt(_ session: Session?) {
        self.session = session
        store.save(session)
    }

    func signIn(identifier: String, password: String) async throws {
        let body = try encoder.encode(CreateSessionRequest(identifier: identifier, password: password))
        let server: ServerSession = try await send("POST", "com.atproto.server.createSession", body: body, contentType: "application/json", authorized: false)
        adopt(Session(server))
    }

    private func refresh() async throws {
        guard let current = session else { throw APIError.invalidResponse }
        if let oauth = current.oauth {
            let form = [("grant_type", "refresh_token"), ("refresh_token", current.refreshJwt), ("client_id", oauth.clientID)]
            let (data, status) = try await postForm(to: oauth.tokenEndpoint, form: form, signer: DPoPSigner(rawKey: oauth.dpopKey))
            guard status == 200 else { throw APIError.http(status: status, code: nil, message: nil) }
            let tokens = try decoder.decode(OAuthRefreshResponse.self, from: data)
            var updated = current
            updated.accessJwt = tokens.accessToken
            updated.refreshJwt = tokens.refreshToken
            adopt(updated)
        } else {
            var request = URLRequest(url: try url(for: "com.atproto.server.refreshSession", query: []))
            request.httpMethod = "POST"
            request.setValue("Bearer \(current.refreshJwt)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await load(request)
            guard status == 200 else { throw APIError.http(status: status, code: nil, message: nil) }
            adopt(Session(try decoder.decode(ServerSession.self, from: data)))
        }
    }

    // MARK: XRPC

    func get<Response: Decodable>(_ method: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send("GET", method, query: query)
    }

    @discardableResult
    func post<Body: Encodable, Response: Decodable>(_ method: String, body: Body) async throws -> Response {
        try await send("POST", method, body: try encoder.encode(body), contentType: "application/json")
    }

    func uploadImage(_ data: Data) async throws -> Blob {
        let response: UploadBlobResponse = try await send("POST", "com.atproto.repo.uploadBlob", body: data, contentType: "image/jpeg")
        return response.blob
    }

    private func url(for method: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseURL + method) else { throw APIError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    private func send<Response: Decodable>(
        _ verb: String,
        _ method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        authorized: Bool = true
    ) async throws -> Response {
        var retriedNonce = false
        var refreshed = false
        while true {
            var request = URLRequest(url: try url(for: method, query: query))
            request.httpMethod = verb
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if method.hasPrefix("chat.") {
                request.setValue("did:web:api.bsky.chat#bsky_chat", forHTTPHeaderField: "atproto-proxy")
            }
            if authorized { try authorize(&request, verb: verb) }

            let (data, status) = try await load(request)
            let failure = try? decoder.decode(ErrorBody.self, from: data)
            if failure?.error == "use_dpop_nonce", !retriedNonce {
                retriedNonce = true
                continue
            }
            let expired = (status == 400 && failure?.error == "ExpiredToken") || (status == 401 && failure?.error == "invalid_token")
            if expired, !refreshed {
                refreshed = true
                try await refresh()
                continue
            }
            guard status == 200 else {
                throw APIError.http(status: status, code: failure?.error, message: failure?.message)
            }
            if let empty = EmptyResponse() as? Response { return empty }
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func authorize(_ request: inout URLRequest, verb: String) throws {
        guard let session, let url = request.url else { return }
        if let oauth = session.oauth {
            let signer = try DPoPSigner(rawKey: oauth.dpopKey)
            request.setValue("DPoP \(session.accessJwt)", forHTTPHeaderField: "Authorization")
            let proof = try signer.proof(method: verb, url: url, accessToken: session.accessJwt, nonce: url.host.flatMap { nonces[$0] })
            request.setValue(proof, forHTTPHeaderField: "DPoP")
        } else {
            request.setValue("Bearer \(session.accessJwt)", forHTTPHeaderField: "Authorization")
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce"), let host = http.url?.host {
            nonces[host] = nonce
        }
        return (data, http.statusCode)
    }

    // MARK: OAuth transport

    func getJSON<Response: Decodable>(_ url: URL) async throws -> Response {
        let (data, status) = try await load(URLRequest(url: url))
        guard status == 200 else { throw APIError.http(status: status, code: nil, message: nil) }
        return try decoder.decode(Response.self, from: data)
    }

    /// Posts a form with a DPoP proof, retrying once when the server asks for a fresh nonce.
    func postForm(to endpoint: URL, form: [(String, String)], signer: DPoPSigner) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.0)=\($0.1.formEncoded)" }.joined(separator: "&").utf8)
        for attempt in 0..<2 {
            let nonce = endpoint.host.flatMap { nonces[$0] }
            request.setValue(try signer.proof(method: "POST", url: endpoint, accessToken: nil, nonce: nonce), forHTTPHeaderField: "DPoP")
            let (data, status) = try await load(request)
            let failure = try? decoder.decode(ErrorBody.self, from: data)
            if attempt == 0, failure?.error == "use_dpop_nonce" { continue }
            return (data, status)
        }
        throw APIError.invalidResponse
    }
}

extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}

private extension Session {
    init(_ server: ServerSession) {
        self.init(
            did: server.did,
            handle: server.handle,
            accessJwt: server.accessJwt,
            refreshJwt: server.refreshJwt,
            serviceEndpoint: server.didDoc?.service?.first?.serviceEndpoint,
            oauth: nil
        )
    }
}

// MARK: - Bluesky operations

extension BlueskyClient {
    private func createRecord<Record: Encodable>(collection: String, record: Record) async throws -> String {
        let created: CreatedRecord = try await post(
            "com.atproto.repo.createRecord",
            body: CreateRecordRequest(repo: did ?? "", collection: collection, record: record)
        )
        return created.uri
    }

    func createSubjectRecord<Subject: Encodable>(collection: String, subject: Subject) async throws -> String {
        try await createRecord(collection: collection, record: SubjectRecord(type: collection, subject: subject))
    }

    func deleteRecord(collection: String, uri: String) async throws {
        let body = DeleteRecordRequest(repo: did ?? "", collection: collection, rkey: uri.split(separator: "/").last.map(String.init) ?? "")
        let _: EmptyResponse = try await post("com.atproto.repo.deleteRecord", body: body)
    }

    func publish(_ post: NewPost) async throws {
        _ = try await createRecord(collection: post.type, record: post)
    }

    func report(_ post: Post, reason: ReportReason) async throws {
        let body = ReportRequest(reasonType: reason.rawValue, subject: .init(uri: post.uri, cid: post.cid))
        let _: EmptyResponse = try await self.post("com.atproto.moderation.createReport", body: body)
    }

    func conversation(with did: String) async throws -> Conversation {
        let response: ConversationResponse = try await get("chat.bsky.convo.getConvoForMembers", query: [URLQueryItem(name: "members", value: did)])
        return response.convo
    }

    func sendMessage(_ text: String, to conversationID: String) async throws {
        let body = SendMessageRequest(convoId: conversationID, message: .init(text: text))
        let _: EmptyResponse = try await post("chat.bsky.convo.sendMessage", body: body)
    }
}
