// Actions, composer, profiles, moderation, notifications, search, media, chat.
import UIKit
import AVKit
import PhotosUI

func me() -> String { str(session, "did") ?? "" }
func isodate() -> String { ISO8601DateFormatter().string(from: Date()) }
func createrec(_ coll: String, _ rec: D, _ done: @escaping Done) {
    xrpc("POST", "com.atproto.repo.createRecord", dict(("repo", me()), ("collection", coll), ("record", rec)), done)
}
func delrec(_ coll: String, _ uri: String, _ done: @escaping Done) {
    xrpc("POST", "com.atproto.repo.deleteRecord", dict(("repo", me()), ("collection", coll), ("rkey", (uri as NSString).lastPathComponent)), done)
}
func strongref(_ p: D) -> D { dict(("uri", at(p, "uri")), ("cid", at(p, "cid"))) }
func present(_ vc: UIViewController, _ x: UIViewController) { vc.present(x, animated: true) }
func sheet(_ t: String?, _ m: String?, _ s: UIAlertController.Style) -> UIAlertController { UIAlertController(title: t, message: m, preferredStyle: s) }
func item(_ a: UIAlertController, _ t: String, _ s: UIAlertAction.Style, _ f: (() -> Void)?) {
    a.addAction(UIAlertAction(title: t, style: s, handler: f.map { g in { _ in g() } }))
}
func alert(_ vc: UIViewController, _ t: String, _ m: String?) {
    let a = sheet(t, m, .alert)
    item(a, "OK", .default, nil)
    present(vc, a)
}
func record(_ coll: String, _ subject: Any?) -> D { dict(("$type", coll), ("subject", subject), ("createdAt", isodate())) }

// ---- moderation. 2 = remove, 1 = cover media, 0 = allow.
func labelrating(_ o: D, _ k: String) -> Int {
    var out = 0
    each(o, k) { l in
        let v = str(l, "val") ?? ""
        if v == "!hide" { out = 2 }
        if out < 2 && (" porn sexual nudity graphic-media gore !warn " as NSString).contains(" " + v + " ") { out = 1 }
    }
    return out
}
func rating(_ p: D) -> Int { max(labelrating(p, "labels"), labelrating(p, "author.labels")) }
func addpost(_ out: inout [D], _ p: D) {
    if rating(p) == 2 || truthy(p, "author.viewer.muted") || at(p, "author.viewer.blocking") != nil || truthy(p, "author.viewer.blockedBy") { return }
    out.append(p)
}

// ---- post content
func bytelen(_ s: NSString, _ n: Int) -> Int {
    NSString(bytes: s.utf8String!, length: min(n, s.lengthOfBytes(using: 4)), encoding: 4)?.length ?? 0
}
func richtext(_ p: D) -> NSAttributedString {
    let t = (str(p, "record.text") ?? "") as NSString
    let m = NSMutableAttributedString(string: t as String)
    let all = NSRange(location: 0, length: t.length)
    m.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: all)
    m.addAttribute(.foregroundColor, value: UIColor.label, range: all)
    each(p, "record.facets") { f in
        let a = bytelen(t, num(f, "index.byteStart")), b = bytelen(t, num(f, "index.byteEnd"))
        if a < b && b <= t.length { m.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(location: a, length: b - a)) }
    }
    return m
}
func firstlink(_ p: D) -> String? {
    var u: String?
    each(p, "record.facets") { f in u = u ?? str(first(f, "features"), "uri") }
    return u ?? str(p, "embed.external.uri")
}
func media(_ p: D) -> String? {
    str(first(p, "embed.images"), "thumb") ?? str(p, "embed.thumbnail") ?? str(p, "embed.external.thumb")
}
func notetext(_ p: D, _ warn: Bool) -> String {
    var out = warn ? "Sensitive media hidden. Use More to show it.\n" : ""
    let n = count(p, "embed.images")
    if n > 1 { out += "+" + String(n - 1) + " more images\n" }
    if at(p, "embed.playlist") != nil { out += "▶ Video\n" }
    if let t = str(p, "embed.external.title") { out += "🔗 " + t + "\n" }
    if let q = str(p, "embed.record.value.text") { out += "❝ " + q + "\n" }
    return out
}

// ---- actions
func toggle(_ vc: Feed, _ post: D, _ key: String, _ countkey: String, _ coll: String) {
    let path = "viewer." + key
    let cur = str(post, path)
    if cur == "pending" { return }
    let n = num(post, countkey)
    func put(_ v: Any?, _ c: Int) {
        post.setValue(v, forKeyPath: path)
        post.setValue(c, forKey: countkey)
    }
    if let cur {
        put(nil, n - 1)
        delrec(coll, cur) { _, c in
            if c != 200 { put(cur, n) }
            vc.tableView.reloadData()
        }
    } else {
        put("pending", n + 1)
        createrec(coll, record(coll, strongref(post))) { j, c in
            if c == 200 { put(at(j, "uri"), n + 1) } else { put(nil, n) }
            vc.tableView.reloadData()
        }
    }
    vc.tableView.reloadData()
}
func postaction(_ vc: Feed, _ p: D, _ w: Int) {
    switch w {
    case 0: compose(vc, p)
    case 1: toggle(vc, p, "repost", "repostCount", "app.bsky.feed.repost")
    case 2: toggle(vc, p, "like", "likeCount", "app.bsky.feed.like")
    case 3: postmenu(vc, p)
    case 4: openmedia(vc, p)
    default: openprofile(vc, str(p, "author.did") ?? "")
    }
}
func postmenu(_ vc: Feed, _ p: D) {
    let a = sheet(nil, nil, .actionSheet)
    if let u = firstlink(p), let url = URL(string: u) { item(a, "Open link", .default) { UIApplication.shared.open(url) } }
    if rating(p) == 1 && at(p, "_reveal") == nil {
        item(a, "Show media", .default) { p.setValue(1, forKey: "_reveal"); vc.tableView.reloadData() }
    }
    let did = str(p, "author.did") ?? ""
    if did == me() {
        item(a, "Delete post", .destructive) { delrec("app.bsky.feed.post", str(p, "uri") ?? "") { _, _ in vc.reload() } }
    } else {
        item(a, "Report post", .destructive) { reportmenu(vc, p) }
        item(a, "Block account", .destructive) {
            createrec("app.bsky.graph.block", record("app.bsky.graph.block", did)) { _, c in
                if c == 200 { vc.reload() } else { alert(vc, "Block failed", nil) }
            }
        }
    }
    item(a, "Cancel", .cancel, nil)
    present(vc, a)
}
func reportmenu(_ vc: Feed, _ p: D) {
    let a = sheet("Report post", "Why are you reporting this?", .actionSheet)
    for (t, r) in [("Spam", "Spam"), ("Harassment", "Rude"), ("Sexual content", "Sexual"), ("Illegal content", "Violation"), ("Other", "Other")] {
        item(a, t, .default) {
            let s = strongref(p)
            s.setValue("com.atproto.repo.strongRef", forKey: "$type")
            xrpc("POST", "com.atproto.moderation.createReport", dict(("reasonType", "com.atproto.moderation.defs#reason" + r), ("subject", s))) { _, c in
                alert(vc, c == 200 ? "Report sent" : "Report failed", nil)
            }
        }
    }
    item(a, "Cancel", .cancel, nil)
    present(vc, a)
}

// ---- media
func openmedia(_ vc: Feed, _ p: D) {
    if let u = str(p, "embed.playlist"), let url = URL(string: u) {
        let v = AVPlayerViewController()
        let pl = AVPlayer(url: url)
        v.player = pl
        vc.present(v, animated: true) { pl.play() }
    } else if let i = first(p, "embed.images") {
        let v = UIViewController()
        v.view.backgroundColor = .systemBackground
        let x = I()
        x.contentMode = .scaleAspectFit
        x.accessibilityLabel = str(i, "alt")
        v.view.addSubview(x)
        pin(x, v.view.safeAreaLayoutGuide)
        loadimage(x, str(i, "fullsize"))
        vc.navigationController?.pushViewController(v, animated: true)
    }
}

// ---- composer
final class ComposeVC: UIViewController, PHPickerViewControllerDelegate {
    var parentPost: D?, from: Feed!, img: UIImage?
    let tv = UITextView(), altf = field("Image description", false)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = parentPost != nil ? "Reply" : "New post"
        tv.font = .preferredFont(forTextStyle: .body)
        tv.accessibilityLabel = "Post text"
        altf.isHidden = true
        let photo = button("Add photo") { [unowned self] in
            var c = PHPickerConfiguration()
            c.selectionLimit = 1
            c.filter = .images
            let p = PHPickerViewController(configuration: c)
            p.delegate = self
            self.present(p, animated: true)
        }
        let s = stack(.vertical, 8, [tv, altf, photo])
        view.addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        let m = view.layoutMarginsGuide
        on(s.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8))
        on(s.leadingAnchor.constraint(equalTo: m.leadingAnchor))
        on(s.trailingAnchor.constraint(equalTo: m.trailingAnchor))
        on(s.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8))
        navigationItem.leftBarButtonItem = barbtn("xmark") { [unowned self] in dismiss(animated: true) }
        navigationItem.rightBarButtonItem = barbtn("paperplane") { [unowned self] in submit() }
        tv.becomeFirstResponder()
    }
    #if TEST
    @objc(attach:) func attach(_ i: UIImage) { attachImage(i) }
    #endif
    func attachImage(_ i: UIImage) { img = i; altf.isHidden = false }
    func picker(_ p: PHPickerViewController, didFinishPicking r: [PHPickerResult]) {
        p.dismiss(animated: true)
        r.first?.itemProvider.loadObject(ofClass: UIImage.self) { o, _ in
            if let i = o as? UIImage { onMain { self.attachImage(i) } }
        }
    }
    func submit() {
        guard !tv.text.isEmpty else { return }
        guard let img else { return publish(nil) }
        let u = host() + "com.atproto.repo.uploadBlob"
        let r = req(u)
        r.httpMethod = "POST"
        authorize(r, "POST", u, token() ?? "")
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        r.httpBody = img.preparingThumbnail(of: CGSize(width: 1600, height: 1600))?.jpegData(compressionQuality: 0.75)
        fetch(r) { j, c in
            if c == 200 {
                self.publish(dict(("$type", "app.bsky.embed.images"), ("images", [dict(("image", at(j, "blob")), ("alt", self.altf.text))])))
            } else { alert(self, "Upload failed", nil) }
        }
    }
    func publish(_ embed: D?) {
        var reply: D?
        if let p = parentPost { reply = dict(("root", at(p, "record.reply.root") ?? strongref(p)), ("parent", strongref(p))) }
        let coll = "app.bsky.feed.post"
        createrec(coll, dict(("$type", coll), ("text", tv.text), ("createdAt", isodate()), ("reply", reply), ("embed", embed))) { j, c in
            if c == 200 {
                self.dismiss(animated: true)
                self.from.reload()
            } else { alert(self, "Could not post", str(j, "message")) }
        }
    }
}
func compose(_ from: Feed, _ parent: D?) {
    let v = ComposeVC()
    v.parentPost = parent
    v.from = from
    present(from, UINavigationController(rootViewController: v))
}

// ---- profiles
final class ProfileCell: Cell {
    let av = imgview(72, 72, 36), name = label(.title2, .label, 1), bio = label(.body, .label, 0), counts = label(.footnote, .secondaryLabel, 1)
    var f: UIButton!, m: UIButton!, b: UIButton!
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        f = btn(.system, "Follow", nil, 0)
        m = btn(.system, "Message", nil, 1)
        b = btn(.system, "Block", nil, 2)
        let s = stack(.vertical, 6, [av, name, bio, counts, stack(.horizontal, 16, [f, m, b, UIView()])])
        host(s)
        s.alignment = .leading
    }
    required init?(coder: NSCoder) { return nil }
}
func profilecell(_ vc: Feed, _ t: UITableView, _ ip: IndexPath, _ p: D) -> UITableViewCell {
    let c = t.dequeueReusableCell(withIdentifier: "h", for: ip) as! ProfileCell
    loadimage(c.av, str(p, "avatar"))
    let dn = str(p, "displayName") ?? ""
    c.name.text = dn.isEmpty ? str(p, "handle") : dn
    c.bio.text = str(p, "description") ?? ""
    c.counts.text = String(num(p, "followersCount")) + " followers · " + String(num(p, "followsCount")) + " following · " + String(num(p, "postsCount")) + " posts"
    let mine = str(p, "did") == me()
    c.f.isHidden = mine; c.b.isHidden = mine; c.m.isHidden = mine
    c.f.setTitle(at(p, "viewer.following") == nil ? "Follow" : "Unfollow", for: .normal)
    c.b.setTitle(at(p, "viewer.blocking") == nil ? "Block" : "Unblock", for: .normal)
    c.act = { [unowned vc] w in profileact(vc, p, w) }
    return c
}
func profileact(_ vc: Feed, _ p: D, _ w: Int) {
    let did = str(p, "did") ?? ""
    if w == 1 { return openchat(vc, did) }
    let key = w == 0 ? "viewer.following" : "viewer.blocking"
    let coll = w == 0 ? "app.bsky.graph.follow" : "app.bsky.graph.block"
    func finish(_ c: Int, _ v: Any?) {
        if c == 200 { p.setValue(v, forKeyPath: key); vc.tableView.reloadData() } else { alert(vc, "Failed", nil) }
    }
    if let cur = str(p, key) {
        delrec(coll, cur) { _, c in finish(c, nil) }
    } else {
        createrec(coll, record(coll, did)) { j, c in finish(c, at(j, "uri")) }
    }
}
func profilevc(_ actor: String) -> Feed {
    feedvc("Profile") { cur, done in
        let path = "app.bsky.feed.getAuthorFeed?limit=30&actor=" + urlq(actor) + cursorq(cur)
        if cur != nil {
            return xrpc("GET", path, nil) { j, c in done(c == 200 ? strippost(j) : nil, str(j, "cursor")) }
        }
        xrpc("GET", "app.bsky.actor.getProfile?actor=" + urlq(actor), nil) { pj, pc in
            xrpc("GET", path, nil) { j, c in
                var out: [D] = []
                if pc == 200, let pj { pj.setValue(1, forKey: "_profile"); out.append(pj) }
                if c == 200 { out += strippost(j) }
                done(out, str(j, "cursor"))
            }
        }
    }
}
func openprofile(_ vc: Feed, _ did: String) { vc.navigationController?.pushViewController(profilevc(did), animated: true) }

// ---- notifications
func reasontext(_ r: String) -> String {
    switch r {
    case "like": return "liked your post"
    case "repost": return "reposted your post"
    case "follow": return "followed you"
    case "reply": return "replied to you"
    case "mention": return "mentioned you"
    case "quote": return "quoted your post"
    default: return r
    }
}
func notifpost(_ n: D) -> D {
    let reason = str(n, "reason") ?? ""
    let subj = at(n, "reasonSubject")
    var body = reasontext(reason)
    if let t = str(n, "record.text") { body += ": " + t }
    return dict(("author", at(n, "author")), ("record", dict(("text", body))), ("_plain", 1),
                ("uri", subj == nil || reason == "reply" || reason == "mention" ? at(n, "uri") : subj),
                ("_follow", reason == "follow" ? 1 : nil))
}
func notifvc() -> Feed {
    feedvc("Alerts") { cur, done in
        xrpc("GET", "app.bsky.notification.listNotifications?limit=40" + cursorq(cur), nil) { j, c in
            var out: [D] = []
            if c == 200 { each(j, "notifications") { out.append(notifpost($0)) } }
            done(out, str(j, "cursor"))
        }
    }
}

// ---- search
func searchvc() -> Feed {
    let v = feedvc("Search") { _, _ in }
    v.load = { [unowned v] cur, done in
        guard let q = v.q else { return done([], nil) }
        xrpc("GET", "app.bsky.feed.searchPosts?limit=30&q=" + urlq(q) + cursorq(cur), nil) { j, c in
            var out: [D] = []
            if c == 200 { each(j, "posts") { addpost(&out, $0) } }
            done(out, str(j, "cursor"))
        }
    }
    let sc = UISearchController(searchResultsController: nil)
    sc.obscuresBackgroundDuringPresentation = false
    sc.searchBar.delegate = v
    v.navigationItem.searchController = sc
    v.navigationItem.hidesSearchBarWhenScrolling = false
    return v
}

// ---- direct messages (not end-to-end encrypted)
func peer(_ convo: D) -> D {
    var hit = first(convo, "members")!
    let all = hit
    each(convo, "members") { if str($0, "did") != me() && str(hit, "did") == str(all, "did") { hit = $0 } }
    return hit
}
func convosvc() -> Feed {
    feedvc("Chats") { _, done in
        xrpc("GET", "chat.bsky.convo.listConvos?limit=40", nil) { j, c in
            var out: [D] = []
            if c == 200 { each(j, "convos") { x in
                out.append(dict(("author", peer(x)), ("_plain", 1), ("_convo", x), ("record", dict(("text", str(x, "lastMessage.text") ?? "No messages yet")))))
            } }
            done(out, nil)
        }
    }
}
func openchat(_ vc: Feed, _ did: String) {
    xrpc("GET", "chat.bsky.convo.getConvoForMembers?members=" + urlq(did), nil) { j, c in
        if c == 200, let x = at(j, "convo") as? D { openconvo(vc, x) } else { alert(vc, "Chat unavailable", str(j, "message")) }
    }
}
final class ChatVC: Feed {
    var bar: UIView?, timer: Timer?
    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }
    override func viewDidAppear(_ a: Bool) {
        super.viewDidAppear(a)
        becomeFirstResponder()
        timer = .scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in reload() }
    }
    override func viewWillDisappear(_ a: Bool) {
        super.viewWillDisappear(a)
        timer?.invalidate()
    }
}
func openconvo(_ vc: Feed, _ convo: D) {
    let v = ChatVC(style: .plain)
    let id = str(convo, "id") ?? ""
    let p = peer(convo)
    v.title = str(p, "handle")
    v.bottom = true
    v.load = { _, done in
        xrpc("GET", "chat.bsky.convo.getMessages?limit=60&convoId=" + urlq(id), nil) { j, _ in
            var out: [D] = []
            each(j, "messages") { m in
                guard let t = str(m, "text") else { return }
                out.insert(dict(("_plain", 1), ("_msg", 1), ("record", dict(("text", t))),
                                ("author", str(m, "sender.did") == me() ? dict(("handle", "You")) : p)), at: 0)
            }
            done(out, nil)
        }
    }
    let bar = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 56))
    bar.autoresizingMask = .flexibleWidth
    bar.backgroundColor = .systemBackground
    let f = field("Message", false)
    let go = button("Send") { [unowned v] in
        guard let t = f.text, !t.isEmpty else { return }
        f.text = ""
        xrpc("POST", "chat.bsky.convo.sendMessage", dict(("convoId", id), ("message", dict(("text", t))))) { j, c in
            if c == 200 { v.reload() } else { alert(v, "Could not send", str(j, "message")) }
        }
    }
    let s = stack(.horizontal, 8, [f, go])
    bar.addSubview(s)
    pin(s, bar.layoutMarginsGuide)
    v.bar = bar
    vc.navigationController?.pushViewController(v, animated: true)
}
