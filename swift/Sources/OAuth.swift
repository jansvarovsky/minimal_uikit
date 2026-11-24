// AT Protocol OAuth (PAR + PKCE + DPoP). All crypto comes from iOS.
import UIKit
import AuthenticationServices
import CommonCrypto

typealias ASWeb = ASWebAuthenticationSession
typealias ASPresenter = ASWebAuthenticationPresentationContextProviding

var nonces: [String: String] = [:]
var dpopKey: SecKey?
var oauth: ASWeb?

func savenonce(_ r: HTTPURLResponse) {
    if let n = r.value(forHTTPHeaderField: "DPoP-Nonce"), let h = r.url?.host { nonces[h] = n }
}
func b64u(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func utf8(_ s: String) -> Data { (s as NSString).data(using: 4) ?? Data() }
func sha256(_ d: Data) -> Data {
    let n = d as NSData, o = NSMutableData(length: 32)!
    CC_SHA256(n.bytes, CC_LONG(n.length), o.mutableBytes)
    return o as Data
}
func uuid() -> String { NSUUID().uuidString }
func rawint(_ o: NSMutableData, _ b: UnsafePointer<UInt8>, _ n: Int) {
    if n < 32 { o.increaseLength(by: 32 - n) }
    o.append(b + max(0, n - 32), length: min(n, 32))
}
func der2raw(_ d: Data) -> Data {
    let n = d as NSData, o = NSMutableData()
    if n.length < 8 { return Data() }
    let b = n.bytes.assumingMemoryBound(to: UInt8.self)
    let rl = Int(b[3])
    rawint(o, b + 4, rl)
    rawint(o, b + 6 + rl, Int(b[5 + rl]))
    return o as Data
}
func external(_ k: SecKey?) -> Data { k.flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } ?? Data() }
func restorekey(_ b64: String) {
    guard let d = Data(base64Encoded: b64) else { return }
    dpopKey = SecKeyCreateWithData(d as CFData, dict(("type", "73"), ("kcls", "1"), ("bsiz", 256)), nil)
}
func ensurekey() { if dpopKey == nil, let k = str(session, "_key") { restorekey(k) } }
func proof(_ verb: String, _ url: String, _ tok: String?) -> String {
    let pub = external(dpopKey.flatMap(SecKeyCopyPublicKey))
    let head = dict(("typ", "dpop+jwt"), ("alg", "ES256"),
                    ("jwk", dict(("kty", "EC"), ("crv", "P-256"), ("x", b64u(pub.subdata(in: 1 ..< 33))), ("y", b64u(pub.subdata(in: 33 ..< 65))))))
    let body = dict(("htm", verb), ("htu", url.components(separatedBy: "?")[0]), ("iat", Int(Date().timeIntervalSince1970)), ("jti", uuid()),
                    ("nonce", URL(string: url)?.host.flatMap { nonces[$0] }), ("ath", tok.map { b64u(sha256(utf8($0))) }))
    let m = b64u(json(head)) + "." + b64u(json(body))
    var sig = Data()
    if let k = dpopKey, let s = SecKeyCreateSignature(k, .ecdsaSignatureMessageX962SHA256, utf8(m) as CFData, nil) { sig = s as Data }
    return m + "." + b64u(der2raw(sig))
}
func authorize(_ r: NSMutableURLRequest, _ verb: String, _ url: String, _ tok: String) {
    if at(session, "_as") != nil {
        ensurekey()
        r.setValue("DPoP " + tok, forHTTPHeaderField: "Authorization")
        r.setValue(proof(verb, url, tok), forHTTPHeaderField: "DPoP")
    } else {
        r.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
    }
}

// ---- discovery
let scope = "atproto transition:generic transition:chat.bsky"
let redirect = "http://127.0.0.1:8123/cb"
func formenc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
// A release client ID is the hosted metadata URL. It is unset until that file is published.
func oauthclient() -> String? {
    getenv("THIMBLE_OAUTH_DEV") == nil ? nil : "http://localhost?redirect_uri=" + formenc(redirect) + "&scope=" + formenc(scope)
}
func getjson(_ u: String, _ done: @escaping Done) { fetch(req(u), done) }
// Retries once when the server asks for a fresh DPoP nonce.
func formpost(_ url: String, _ pairs: [(String, String)], _ done: @escaping Done, again: Bool = true) {
    let r = req(url)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.setValue(proof("POST", url, nil), forHTTPHeaderField: "DPoP")
    r.httpBody = utf8(pairs.map { $0.0 + "=" + formenc($0.1) }.joined(separator: "&"))
    fetch(r) { j, c in
        if again && str(j, "error") == "use_dpop_nonce" { formpost(url, pairs, done, again: false) } else { done(j, c) }
    }
}
func oauthstart(_ vc: LoginVC, _ handle: String, _ err: UILabel) {
    err.text = ""
    if handle.isEmpty { err.text = "Enter your handle first"; return }
    getjson("https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=" + urlq(handle)) { r, c in
        guard c == 200, let did = str(r, "did") else { err.text = "Handle not found"; return }
        getjson("https://plc.directory/" + did) { doc, _ in
            var hit: D?
            each(doc, "service") { if str($0, "id") == "#atproto_pds" { hit = $0 } }
            guard let pds = str(hit, "serviceEndpoint") else {
                err.text = "Could not find your server"
                return
            }
            getjson(pds + "/.well-known/oauth-protected-resource") { pr, _ in
                guard let a = (at(pr, "authorization_servers") as? [String])?.first else { return }
                getjson(a + "/.well-known/oauth-authorization-server") { meta, _ in par(vc, handle, did, pds, meta, err) }
            }
        }
    }
}
func par(_ vc: LoginVC, _ handle: String, _ did: String, _ pds: String, _ meta: D?, _ err: UILabel) {
    dpopKey = SecKeyCreateRandomKey(dict(("type", "73"), ("bsiz", 256)), nil)
    let verifier = (uuid() + uuid()).replacingOccurrences(of: "-", with: "")
    let state = uuid()
    let client = oauthclient() ?? ""
    formpost(str(meta, "pushed_authorization_request_endpoint") ?? "",
             [("client_id", client), ("response_type", "code"), ("redirect_uri", redirect), ("scope", scope), ("state", state),
              ("code_challenge", b64u(sha256(utf8(verifier)))), ("code_challenge_method", "S256"), ("login_hint", handle)]) { j, c in
        guard c == 201, let uri = str(j, "request_uri") else { err.text = "Sign-in could not start"; return }
        let s = ASWeb(url: URL(string: (str(meta, "authorization_endpoint") ?? "") + "?client_id=" + formenc(client) + "&request_uri=" + formenc(uri))!,
                      callbackURLScheme: "thimble") { cb, _ in
            guard let cb else { err.text = "Sign-in cancelled"; return }
            redeem(cb, state, verifier, client, did, pds, handle, meta, err)
        }
        s.presentationContextProvider = vc
        oauth = s
        s.start()
    }
}
func query(_ u: URL, _ n: String) -> String? {
    NSURLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == n }?.value
}
func redeem(_ cb: URL, _ state: String, _ verifier: String, _ client: String, _ did: String, _ pds: String, _ handle: String, _ meta: D?, _ err: UILabel) {
    if query(cb, "state") != state { err.text = "Sign-in failed: state mismatch"; return }
    let tokurl = str(meta, "token_endpoint") ?? ""
    formpost(tokurl, [("grant_type", "authorization_code"), ("code", query(cb, "code") ?? ""), ("redirect_uri", redirect), ("client_id", client), ("code_verifier", verifier)]) { j, c in
        guard c == 200, str(j, "sub") == did else { err.text = "Sign-in failed"; return }
        savesession(dict(("did", did), ("handle", handle), ("accessJwt", at(j, "access_token")), ("refreshJwt", at(j, "refresh_token")),
                         ("didDoc", dict(("service", [dict(("serviceEndpoint", pds))]))),
                         ("_as", tokurl), ("_client", client), ("_key", external(dpopKey).base64EncodedString())))
        showmain()
    }
}
func oauthrefresh(_ retry: @escaping () -> Void, _ fail: @escaping Done) {
    ensurekey()
    formpost(str(session, "_as") ?? "", [("grant_type", "refresh_token"), ("refresh_token", str(session, "refreshJwt") ?? ""), ("client_id", str(session, "_client") ?? "")]) { j, c in
        guard c == 200 else { return fail(nil, c) }
        let s = D(dictionary: session ?? D())
        s.setValue(at(j, "access_token"), forKey: "accessJwt")
        s.setValue(at(j, "refresh_token"), forKey: "refreshJwt")
        savesession(s)
        retry()
    }
}
