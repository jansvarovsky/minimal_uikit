import AVKit
import UIKit

class FeedViewController: UITableViewController {
    let client: BlueskyClient
    var source: any FeedSource
    var scrollsToBottomOnChange = false

    private var items: [FeedItem] = []
    private var cursor: String?
    private var isLoading = false
    private var engagementsInFlight = Set<String>()

    init(client: BlueskyClient, title: String, source: any FeedSource) {
        self.client = client
        self.source = source
        super.init(style: .plain)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(PostCell.self, forCellReuseIdentifier: PostCell.reuseIdentifier)
        tableView.register(ProfileCell.self, forCellReuseIdentifier: ProfileCell.reuseIdentifier)
        tableView.estimatedRowHeight = 200
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        refreshControl = refresh
        reload()
    }

    // MARK: Loading

    func reload() {
        cursor = nil
        isLoading = true
        Task {
            let page = try? await source.page(cursor: nil)
            isLoading = false
            refreshControl?.endRefreshing()
            let previousCount = items.count
            items = page?.items ?? []
            cursor = page?.cursor
            tableView.reloadData()
            if scrollsToBottomOnChange, previousCount != items.count, !items.isEmpty {
                tableView.scrollToRow(at: IndexPath(row: items.count - 1, section: 0), at: .bottom, animated: false)
            }
        }
    }

    private func loadMore() {
        guard let cursor, !isLoading else { return }
        isLoading = true
        Task {
            let page = try? await source.page(cursor: cursor)
            isLoading = false
            items += page?.items ?? []
            self.cursor = page?.cursor
            tableView.reloadData()
        }
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row + 6 > items.count { loadMore() }
        let item = items[indexPath.row]
        if case .profile(let profile) = item {
            let cell = tableView.dequeueReusableCell(withIdentifier: ProfileCell.reuseIdentifier, for: indexPath) as! ProfileCell
            cell.configure(with: profile, isCurrentUser: profile.did == client.did)
            cell.onAction = { [weak self] action in self?.handle(action, profile: profile) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: PostCell.reuseIdentifier, for: indexPath) as! PostCell
        cell.onAction = nil
        switch item {
        case .post(let post):
            cell.configure(with: PostCell.Model(post: post))
            cell.onAction = { [weak self] action in self?.handle(action, uri: post.uri) }
        case .notification(let notification):
            cell.configure(with: PostCell.Model(plain: notification.summary, author: notification.author))
        case .conversation(let conversation, let peer):
            cell.configure(with: PostCell.Model(plain: conversation.lastMessage?.text ?? "No messages yet", author: peer))
        case .message(let text, let author):
            cell.configure(with: PostCell.Model(plain: text, author: author, showsHandle: false))
        case .profile:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch items[indexPath.row] {
        case .post(let post):
            openThread(uri: post.uri)
        case .notification(let notification):
            if notification.reason == "follow", let did = notification.author.did {
                openProfile(did)
            } else {
                openThread(uri: notification.targetURI)
            }
        case .conversation(let conversation, let peer):
            openChat(conversation, peer: peer)
        case .profile, .message:
            break
        }
    }

    // MARK: Navigation

    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openThread(uri: String) {
        push(FeedViewController(client: client, title: "Thread", source: ThreadSource(client: client, uri: uri)))
    }

    private func openProfile(_ did: String) {
        push(FeedViewController(client: client, title: "Profile", source: AuthorFeedSource(client: client, actor: did)))
    }

    private func openChat(_ conversation: Conversation, peer: Author) {
        push(ChatViewController(client: client, conversation: conversation, peer: peer))
    }

    func compose(replyingTo parent: Post?) {
        let composer = ComposeViewController(client: client, parent: parent) { [weak self] in self?.reload() }
        present(UINavigationController(rootViewController: composer), animated: true)
    }

    // MARK: Post actions

    private func post(uri: String) -> Post? {
        for case .post(let post) in items where post.uri == uri { return post }
        return nil
    }

    private func update(uri: String, _ change: (inout Post) -> Void) {
        for index in items.indices {
            if case .post(var post) = items[index], post.uri == uri {
                change(&post)
                items[index] = .post(post)
            }
        }
        tableView.reloadData()
    }

    private func handle(_ action: PostAction, uri: String) {
        guard let post = post(uri: uri) else { return }
        switch action {
        case .reply: compose(replyingTo: post)
        case .like: toggle(.like, on: post)
        case .repost: toggle(.repost, on: post)
        case .menu: showMenu(for: post)
        case .media: openMedia(of: post)
        case .profile:
            if let did = post.author.did { openProfile(did) }
        }
    }

    private func toggle(_ kind: Engagement, on post: Post) {
        let key = "\(post.uri)|\(kind.collection)"
        guard engagementsInFlight.insert(key).inserted else { return }
        let count = post.count(of: kind)
        let existing = post.engagementURI(kind)
        update(uri: post.uri) { $0.setEngagement(kind, uri: existing == nil ? "pending" : nil, count: count + (existing == nil ? 1 : -1)) }
        Task {
            defer { engagementsInFlight.remove(key) }
            do {
                if let existing {
                    try await client.deleteRecord(collection: kind.collection, uri: existing)
                } else {
                    let created = try await client.createSubjectRecord(collection: kind.collection, subject: post.ref)
                    update(uri: post.uri) { $0.setEngagement(kind, uri: created, count: count + 1) }
                }
            } catch {
                update(uri: post.uri) { $0.setEngagement(kind, uri: existing, count: count) }
            }
        }
    }

    private func showMenu(for post: Post) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if let link = post.firstLink, let url = URL(string: link) {
            sheet.addAction(UIAlertAction(title: "Open link", style: .default) { _ in UIApplication.shared.open(url) })
        }
        if post.moderation == .coverMedia, !post.isMediaRevealed {
            sheet.addAction(UIAlertAction(title: "Show media", style: .default) { [weak self] _ in
                self?.update(uri: post.uri) { $0.isMediaRevealed = true }
            })
        }
        if post.author.did == client.did {
            sheet.addAction(UIAlertAction(title: "Delete post", style: .destructive) { [weak self] _ in self?.delete(post) })
        } else {
            sheet.addAction(UIAlertAction(title: "Report post", style: .destructive) { [weak self] _ in self?.showReportMenu(for: post) })
            sheet.addAction(UIAlertAction(title: "Block account", style: .destructive) { [weak self] _ in self?.block(post.author.did) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func showReportMenu(for post: Post) {
        let sheet = UIAlertController(title: "Report post", message: "Why are you reporting this?", preferredStyle: .actionSheet)
        for reason in ReportReason.allCases {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { [weak self] _ in self?.report(post, reason: reason) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func report(_ post: Post, reason: ReportReason) {
        Task {
            do {
                try await client.report(post, reason: reason)
                showAlert("Report sent")
            } catch {
                showAlert("Report failed")
            }
        }
    }

    private func delete(_ post: Post) {
        Task {
            try? await client.deleteRecord(collection: "app.bsky.feed.post", uri: post.uri)
            reload()
        }
    }

    private func block(_ did: String?) {
        guard let did else { return }
        Task {
            do {
                _ = try await client.createSubjectRecord(collection: "app.bsky.graph.block", subject: did)
                reload()
            } catch {
                showAlert("Block failed")
            }
        }
    }

    private func openMedia(of post: Post) {
        if let playlist = post.embed?.playlist, let url = URL(string: playlist) {
            let controller = AVPlayerViewController()
            let player = AVPlayer(url: url)
            controller.player = player
            present(controller, animated: true) { player.play() }
        } else if let image = post.embed?.images?.first {
            push(ImageViewController(address: image.fullsize, description: image.alt))
        }
    }

    // MARK: Profile actions

    private func handle(_ action: ProfileAction, profile: Profile) {
        switch action {
        case .message:
            Task {
                do {
                    let conversation = try await client.conversation(with: profile.did)
                    if let peer = conversation.peer(of: client.did) { openChat(conversation, peer: peer) }
                } catch {
                    showAlert("Chat unavailable", message: error.localizedDescription)
                }
            }
        case .follow:
            toggleRelationship(on: profile, collection: "app.bsky.graph.follow", current: profile.viewer?.following) { $0.following = $1 }
        case .block:
            toggleRelationship(on: profile, collection: "app.bsky.graph.block", current: profile.viewer?.blocking) { $0.blocking = $1 }
        }
    }

    private func toggleRelationship(on profile: Profile, collection: String, current: String?, apply: @escaping (inout ProfileViewerState, String?) -> Void) {
        Task {
            do {
                var created: String?
                if let current {
                    try await client.deleteRecord(collection: collection, uri: current)
                } else {
                    created = try await client.createSubjectRecord(collection: collection, subject: profile.did)
                }
                for index in items.indices {
                    if case .profile(var value) = items[index], value.did == profile.did {
                        var state = value.viewer ?? ProfileViewerState()
                        apply(&state, created)
                        value.viewer = state
                        items[index] = .profile(value)
                    }
                }
                tableView.reloadData()
            } catch {
                showAlert("Failed")
            }
        }
    }
}

final class ImageViewController: UIViewController {
    private let address: String?
    private let imageDescription: String?

    init(address: String?, description: String?) {
        self.address = address
        imageDescription = description
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let image = RemoteImageView(frame: .zero)
        image.contentMode = .scaleAspectFit
        image.accessibilityLabel = imageDescription
        view.addSubview(image)
        image.pinEdges(to: view.safeAreaLayoutGuide)
        image.load(address)
    }
}

final class SearchViewController: FeedViewController, UISearchBarDelegate {
    init(client: BlueskyClient) {
        super.init(client: client, title: "Search", source: SearchSource(client: client))
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.delegate = self
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        source = SearchSource(client: client, term: searchBar.text)
        searchBar.resignFirstResponder()
        reload()
    }
}

final class ChatViewController: FeedViewController {
    private let conversationID: String
    private let inputBar = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 56))
    private let messageField = UITextField(placeholder: "Message")
    private var timer: Timer?

    init(client: BlueskyClient, conversation: Conversation, peer: Author) {
        conversationID = conversation.id
        super.init(client: client, title: peer.handle, source: MessagesSource(client: client, conversation: conversation, peer: peer))
        scrollsToBottomOnChange = true
    }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { inputBar }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputBar.autoresizingMask = .flexibleWidth
        inputBar.backgroundColor = .systemBackground
        let send = UIButton(title: "Send") { [weak self] in self?.send() }
        let stack = UIStackView(axis: .horizontal, spacing: 8, arranged: [messageField, send])
        inputBar.addSubview(stack)
        stack.pinEdges(to: inputBar.layoutMarginsGuide)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        timer = .scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
    }

    private func send() {
        guard let text = messageField.text, !text.isEmpty else { return }
        messageField.text = ""
        Task {
            do {
                try await client.sendMessage(text, to: conversationID)
                reload()
            } catch {
                showAlert("Could not send", message: error.localizedDescription)
            }
        }
    }
}
