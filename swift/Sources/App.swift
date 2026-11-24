// Thimble in plain Swift: the same app as app/*.tl, with no VM. Core screens.
import UIKit

typealias D = NSMutableDictionary
typealias Done = (D?, Int) -> Void
typealias Load = (String?, @escaping ([D]?, String?) -> Void) -> Void

var session: D?
var cache: NSCache<NSString, UIImage>!
var win: UIWindow!

// ---- JSON helpers. JSON null reads as nil.
@inline(never) func at(_ o: NSObject?, _ k: String) -> Any? {
    let v = o?.value(forKeyPath: k)
    return v is NSNull ? nil : v
}
@inline(never) func str(_ o: NSObject?, _ k: String) -> String? { at(o, k) as? String }
@inline(never) func each(_ o: NSObject?, _ k: String, _ f: (D) -> Void) {
    guard let a = at(o, k) as? NSArray else { return }
    for x in a { f(x as! D) }
}
@inline(never) func first(_ o: NSObject?, _ k: String) -> D? { (at(o, k) as? NSArray)?.firstObject as? D }
@inline(never) func count(_ o: NSObject?, _ k: String) -> Int { (at(o, k) as? NSArray)?.count ?? 0 }
func num(_ o: NSObject?, _ k: String) -> Int { (at(o, k) as? NSNumber)?.intValue ?? 0 }
func truthy(_ o: NSObject?, _ k: String) -> Bool { (at(o, k) as? NSNumber)?.boolValue ?? false }
@inline(never) func dict(_ p: (String, Any?)...) -> D {
    let m = D()
    for (k, v) in p { m.setValue(v, forKey: k) }
    return m
}
func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
func parse(_ d: Data?) -> D? {
    guard let d else { return nil }
    return (try? JSONSerialization.jsonObject(with: d, options: .mutableContainers)) as? D
}
func onMain(_ f: @escaping () -> Void) { OperationQueue.main.addOperation(f) }

// ---- UI helpers
func label(_ s: UIFont.TextStyle, _ c: UIColor, _ n: Int) -> UILabel {
    let l = UILabel()
    l.font = .preferredFont(forTextStyle: s)
    l.textColor = c
    l.numberOfLines = n
    l.adjustsFontForContentSizeCategory = true
    return l
}
func stack(_ a: NSLayoutConstraint.Axis, _ sp: CGFloat, _ v: [UIView]) -> UIStackView {
    let s = UIStackView()
    s.axis = a
    s.spacing = sp
    for x in v { s.addArrangedSubview(x) }
    return s
}
func on(_ c: NSLayoutConstraint) { c.isActive = true }
func edges(_ v: UIView, _ t: NSLayoutYAxisAnchor, _ l: NSLayoutXAxisAnchor, _ b: NSLayoutYAxisAnchor, _ r: NSLayoutXAxisAnchor) {
    v.translatesAutoresizingMaskIntoConstraints = false
    on(v.topAnchor.constraint(equalTo: t))
    on(v.leadingAnchor.constraint(equalTo: l))
    on(v.bottomAnchor.constraint(equalTo: b))
    on(v.trailingAnchor.constraint(equalTo: r))
}
func pin(_ v: UIView, _ g: UILayoutGuide) { edges(v, g.topAnchor, g.leadingAnchor, g.bottomAnchor, g.trailingAnchor) }
func sym(_ n: String) -> UIImage? { UIImage(systemName: n) }
func button(_ t: String, _ f: @escaping () -> Void) -> UIButton {
    let x = UIButton(type: .system)
    x.setTitle(t, for: .normal)
    x.addAction(UIAction { _ in f() }, for: .primaryActionTriggered)
    return x
}
func barbtn(_ i: String, _ f: @escaping () -> Void) -> UIBarButtonItem {
    UIBarButtonItem(primaryAction: UIAction(image: sym(i)) { _ in f() })
}
func field(_ ph: String, _ secure: Bool) -> UITextField {
    let f = UITextField()
    f.placeholder = ph
    f.isSecureTextEntry = secure
    f.borderStyle = .roundedRect
    f.autocapitalizationType = .none
    f.autocorrectionType = .no
    return f
}
func urlq(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
func cursorq(_ c: String?) -> String { c.map { "&cursor=" + urlq($0) } ?? "" }

// ---- session storage (Keychain)
func kquery() -> D { dict(("class", "genp"), ("svce", "thimble"), ("acct", "s")) }
func savesession(_ s: D?) {
    session = s
    SecItemDelete(kquery())
    if let s {
        let q = kquery()
        q.setValue(json(s), forKey: "v_Data")
        SecItemAdd(q, nil)
    }
}
func loadsession() {
    let q = kquery()
    q.setValue(true, forKey: "r_Data")
    var out: CFTypeRef?
    if SecItemCopyMatching(q, &out) == 0 { session = parse(out as? Data) }
}

// ---- XRPC
func host() -> String {
    guard let e = first(session, "didDoc.service") else { return "https://bsky.social/xrpc/" }
    return str(e, "serviceEndpoint")! + "/xrpc/"
}
func req(_ u: String) -> NSMutableURLRequest { NSMutableURLRequest(url: URL(string: u)!) }
func request(_ verb: String, _ path: String, _ body: D?, _ tok: String?) -> NSMutableURLRequest {
    let u = host() + path
    let r = req(u)
    r.httpMethod = verb
    if let tok { authorize(r, verb, u, tok) }
    if path.hasPrefix("chat.") { r.setValue("did:web:api.bsky.chat#bsky_chat", forHTTPHeaderField: "atproto-proxy") }
    if let body {
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = json(body)
    }
    return r
}
func fetch(_ r: NSMutableURLRequest, _ done: @escaping Done) {
    URLSession.shared.dataTask(with: r as URLRequest) { d, rs, _ in
        onMain {
            let h = rs as? HTTPURLResponse
            if let h { savenonce(h) }
            done(parse(d), h?.statusCode ?? 0)
        }
    }.resume()
}
func token() -> String? { str(session, "accessJwt") }
func relogin(_ retry: @escaping () -> Void, _ fail: @escaping Done) {
    if at(session, "_as") != nil { return oauthrefresh(retry, fail) }
    fetch(request("POST", "com.atproto.server.refreshSession", nil, str(session, "refreshJwt"))) { j, c in
        if c == 200 { savesession(j); retry() } else { fail(nil, c) }
    }
}
func xrpc(_ verb: String, _ path: String, _ body: D?, _ done: @escaping Done) {
    fetch(request(verb, path, body, token())) { j, c in
        let e = str(j, "error")
        if e == "use_dpop_nonce" { return fetch(request(verb, path, body, token()), done) }
        if (c == 400 && e == "ExpiredToken") || (c == 401 && e == "invalid_token") {
            relogin({ fetch(request(verb, path, body, token()), done) }, done)
        } else { done(j, c) }
    }
}

// ---- images
final class I: UIImageView { var u: String? }
func loadimage(_ v: I, _ url: String?) {
    v.image = nil
    v.u = url
    guard let url else { return }
    if let hit = cache.object(forKey: url as NSString) { v.image = hit; return }
    URLSession.shared.dataTask(with: req(url) as URLRequest) { d, _, _ in
        guard let d, let img = UIImage(data: d) else { return }
        onMain {
            cache.setObject(img, forKey: url as NSString)
            if v.u == url { v.image = img }
        }
    }.resume()
}
func imgview(_ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> I {
    let v = I()
    v.contentMode = .scaleAspectFill
    v.clipsToBounds = true
    v.layer.cornerRadius = r
    v.backgroundColor = .secondarySystemBackground
    v.translatesAutoresizingMaskIntoConstraints = false
    if w > 0 { on(v.widthAnchor.constraint(equalToConstant: w)) }
    on(v.heightAnchor.constraint(equalToConstant: h))
    return v
}

// ---- cells. Buttons report their tag through `act`.
class Cell: UITableViewCell {
    var act: ((Int) -> Void)?
    @objc func hit(_ b: UIView) { act?(b.tag) }
    func btn(_ type: UIButton.ButtonType, _ title: String?, _ name: String?, _ tag: Int) -> UIButton {
        let x = UIButton(type: type)
        x.setTitle(title, for: .normal)
        x.accessibilityLabel = name
        x.tag = tag
        x.addTarget(self, action: #selector(hit), for: .primaryActionTriggered)
        return x
    }
    func overlay(_ v: UIView, _ name: String, _ tag: Int) {
        let x = btn(.custom, nil, name, tag)
        v.isUserInteractionEnabled = true
        v.addSubview(x)
        edges(x, v.topAnchor, v.leadingAnchor, v.bottomAnchor, v.trailingAnchor)
    }
    func host(_ s: UIStackView) {
        selectionStyle = .none
        s.alignment = .fill
        contentView.addSubview(s)
        pin(s, contentView.layoutMarginsGuide)
    }
    required init?(coder: NSCoder) { return nil }
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) { super.init(style: style, reuseIdentifier: reuseIdentifier) }
}
func setcount(_ b: UIButton, _ n: Int, _ name: String) {
    b.setTitle(" " + String(n), for: .normal)
    b.setImage(sym(name), for: .normal)
}
final class PostCell: Cell {
    let av = imgview(44, 44, 22), img = imgview(0, 220, 10)
    let head = label(.subheadline, .secondaryLabel, 1), body = label(.body, .label, 0), note = label(.footnote, .secondaryLabel, 0)
    var reply: UIButton!, repost: UIButton!, like: UIButton!, bar: UIStackView!
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        reply = btn(.system, "0", "Reply", 0)
        repost = btn(.system, "0", "Repost", 1)
        like = btn(.system, "0", "Like", 2)
        let dots = btn(.system, "", "More", 3)
        dots.setImage(sym("ellipsis"), for: .normal)
        overlay(img, "Open media", 4)
        overlay(av, "Open profile", 5)
        bar = stack(.horizontal, 28, [reply, repost, like, UIView(), dots])
        let root = stack(.horizontal, 10, [av, stack(.vertical, 4, [head, body, note, img, bar])])
        host(root)
        root.alignment = .top
    }
    required init?(coder: NSCoder) { return nil }
    func fill(_ post: D) {
        let a = at(post, "author") as? D
        let dn = str(a, "displayName") ?? ""
        let handle = str(a, "handle") ?? ""
        head.text = (dn.isEmpty ? handle : dn) + (at(post, "_msg") != nil ? "" : "  @" + handle)
        body.attributedText = richtext(post)
        loadimage(av, str(a, "avatar"))
        let m = media(post)
        let warn = m != nil && rating(post) == 1 && at(post, "_reveal") == nil
        img.isHidden = m == nil || warn
        if !img.isHidden { loadimage(img, m) }
        note.text = notetext(post, warn)
        note.isHidden = note.text?.isEmpty ?? true
        bar.isHidden = at(post, "_plain") != nil
        setcount(reply, num(post, "replyCount"), "bubble.left")
        setcount(repost, num(post, "repostCount"), at(post, "viewer.repost") == nil ? "arrow.2.squarepath" : "checkmark.circle")
        setcount(like, num(post, "likeCount"), at(post, "viewer.like") == nil ? "heart" : "heart.fill")
    }
}

// ---- generic feed
class Feed: UITableViewController, UISearchBarDelegate {
    var items: [D] = [], cursor: String?, busy = false, bottom = false, q: String?
    var load: Load = { _, _ in }
    override func viewDidLoad() {
        super.viewDidLoad()
        let t = tableView!
        t.register(PostCell.self, forCellReuseIdentifier: "p")
        t.register(ProfileCell.self, forCellReuseIdentifier: "h")
        t.estimatedRowHeight = 200
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(reload), for: .valueChanged)
        refreshControl = rc
        reload()
    }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { items.count }
    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let post = items[ip.row]
        if ip.row + 6 > items.count { more() }
        if at(post, "_profile") != nil { return profilecell(self, t, ip, post) }
        let c = t.dequeueReusableCell(withIdentifier: "p", for: ip) as! PostCell
        c.fill(post)
        c.act = { [unowned self] w in postaction(self, post, w) }
        return c
    }
    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        let p = items[ip.row]
        if at(p, "_profile") != nil || at(p, "_msg") != nil { return }
        if let c = at(p, "_convo") as? D { return openconvo(self, c) }
        if at(p, "_follow") != nil { return openprofile(self, str(p, "author.did")!) }
        openthread(self, p)
    }
    func searchBarSearchButtonClicked(_ b: UISearchBar) {
        q = b.text
        b.resignFirstResponder()
        reload()
    }
    @objc func reload() {
        cursor = nil
        busy = true
        load(nil) { posts, cur in
            self.busy = false
            self.refreshControl?.endRefreshing()
            let before = self.items.count
            self.items = posts ?? []
            self.cursor = cur
            self.tableView.reloadData()
            if self.bottom && before != self.items.count { self.scrollEnd() }
        }
    }
    func scrollEnd() {
        if !items.isEmpty { tableView.scrollToRow(at: IndexPath(row: items.count - 1, section: 0), at: .bottom, animated: false) }
    }
    func more() {
        guard let c = cursor, !busy else { return }
        busy = true
        load(c) { posts, cur in
            self.busy = false
            self.items += posts ?? []
            self.cursor = cur
            self.tableView.reloadData()
        }
    }
}
func feedvc(_ title: String, _ load: @escaping Load) -> Feed {
    let v = Feed(style: .plain)
    v.title = title
    v.load = load
    return v
}
func strippost(_ j: D?) -> [D] {
    var out: [D] = []
    each(j, "feed") { x in if let p = at(x, "post") as? D { addpost(&out, p) } }
    return out
}
func timelinevc() -> Feed {
    feedvc("Home") { cur, done in
        xrpc("GET", "app.bsky.feed.getTimeline?limit=30" + cursorq(cur), nil) { j, c in
            done(c == 200 ? strippost(j) : nil, str(j, "cursor"))
        }
    }
}
func collect(_ n: D?, _ out: inout [D]) {
    guard let n else { return }
    collect(at(n, "parent") as? D, &out)
    if let p = at(n, "post") as? D { addpost(&out, p) }
}
func threadposts(_ t: D?) -> [D] {
    var out: [D] = []
    collect(t, &out)
    each(t, "replies") { r in if let p = at(r, "post") as? D { addpost(&out, p) } }
    return out
}
func openthread(_ from: Feed, _ post: D) {
    let uri = str(post, "uri") ?? ""
    from.navigationController?.pushViewController(feedvc("Thread") { _, done in
        xrpc("GET", "app.bsky.feed.getPostThread?depth=1&uri=" + urlq(uri), nil) { j, c in
            done(c == 200 ? threadposts(at(j, "thread") as? D) : nil, nil)
        }
    }, animated: true)
}

// ---- login
final class LoginVC: UIViewController, ASPresenter {
    func presentationAnchor(for s: ASWeb) -> UIWindow { win }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = label(UIFont.TextStyle(rawValue: "UICTFontTextStyleTitle0"), .label, 1)
        title.text = "Thimble"
        let hf = field("Handle", false), pf = field("App password", true)
        let err = label(.footnote, .systemRed, 0)
        let go = button("Sign in") {
            err.text = ""
            fetch(request("POST", "com.atproto.server.createSession", dict(("identifier", hf.text), ("password", pf.text)), nil)) { j, c in
                if c == 200 { savesession(j); showmain() } else { err.text = str(j, "message") ?? "Sign-in failed" }
            }
        }
        let br = button("Sign in with browser") { [unowned self] in oauthstart(self, hf.text ?? "", err) }
        br.isHidden = oauthclient() == nil
        let s = stack(.vertical, 14, [title, hf, pf, go, br, err])
        view.addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        let g = view.layoutMarginsGuide
        on(s.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40))
        on(s.leadingAnchor.constraint(equalTo: g.leadingAnchor))
        on(s.trailingAnchor.constraint(equalTo: g.trailingAnchor))
    }
}

// ---- root
func tab(_ vc: UIViewController, _ t: String, _ i: String) -> UIViewController {
    let n = UINavigationController(rootViewController: vc)
    n.tabBarItem = UITabBarItem(title: t, image: sym(i), tag: 0)
    return n
}
func showmain() {
    let t = UITabBarController()
    let home = timelinevc()
    home.navigationItem.rightBarButtonItem = barbtn("square.and.pencil") { [unowned home] in compose(home, nil) }
    let you = profilevc(me())
    you.title = "You"
    you.navigationItem.rightBarButtonItem = barbtn("rectangle.portrait.and.arrow.right") {
        savesession(nil)
        win.rootViewController = LoginVC()
    }
    t.viewControllers = [tab(home, "Home", "house"), tab(searchvc(), "Search", "magnifyingglass"),
                         tab(notifvc(), "Alerts", "bell"), tab(convosvc(), "Chats", "bubble.left.and.bubble.right"), tab(you, "You", "person")]
    win.rootViewController = t
}

@main final class A: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    func application(_ a: UIApplication, configurationForConnecting s: UISceneSession, options o: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: s.role)
        c.delegateClass = A.self
        return c
    }
    func scene(_ scene: UIScene, willConnectTo s: UISceneSession, options o: UIScene.ConnectionOptions) {
        #if TEST
        ts_test_start()
        #endif
        cache = NSCache()
        win = UIWindow(windowScene: scene as! UIWindowScene)
        loadsession()
        if session != nil { showmain() } else { win.rootViewController = LoginVC() }
        win.makeKeyAndVisible()
    }
}
