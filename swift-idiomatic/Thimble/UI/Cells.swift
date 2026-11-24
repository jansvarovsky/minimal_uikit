import UIKit

enum PostAction {
    case reply, repost, like, menu, media, profile
}

final class PostCell: UITableViewCell {
    static let reuseIdentifier = "post"

    struct Model {
        var headline: String
        var body: NSAttributedString
        var avatar: String?
        var media: String?
        var note = ""
        var showsActions = false
        var replies = 0
        var reposts = 0
        var likes = 0
        var isLiked = false
        var isReposted = false
    }

    var onAction: ((PostAction) -> Void)?

    private let avatar = RemoteImageView(width: 44, height: 44, cornerRadius: 22)
    private let media = RemoteImageView(height: 220, cornerRadius: 10)
    private let headline = UILabel(style: .subheadline, color: .secondaryLabel, lines: 1)
    private let body = UILabel(style: .body)
    private let note = UILabel(style: .footnote, color: .secondaryLabel)
    private lazy var replyButton = makeButton(label: "Reply", action: .reply)
    private lazy var repostButton = makeButton(label: "Repost", action: .repost)
    private lazy var likeButton = makeButton(label: "Like", action: .like)
    private lazy var menuButton = makeButton(label: "More", action: .menu)
    private lazy var actionBar = UIStackView(axis: .horizontal, spacing: 28, arranged: [replyButton, repostButton, likeButton, UIView(), menuButton])

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        addOverlay(to: media, label: "Open media", action: .media)
        addOverlay(to: avatar, label: "Open profile", action: .profile)

        let column = UIStackView(axis: .vertical, spacing: 4, arranged: [headline, body, note, media, actionBar])
        let row = UIStackView(axis: .horizontal, spacing: 10, arranged: [avatar, column])
        row.alignment = .top
        contentView.addSubview(row)
        row.pinEdges(to: contentView.layoutMarginsGuide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(label: String, action: PostAction) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .primaryActionTriggered)
        return button
    }

    private func addOverlay(to view: UIView, label: String, action: PostAction) {
        let button = UIButton(type: .custom)
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .primaryActionTriggered)
        view.isUserInteractionEnabled = true
        view.fill(with: button)
    }

    func configure(with model: Model) {
        headline.text = model.headline
        body.attributedText = model.body
        avatar.load(model.avatar)
        media.isHidden = model.media == nil
        media.load(model.media)
        note.text = model.note
        note.isHidden = model.note.isEmpty
        actionBar.isHidden = !model.showsActions
        Self.set(replyButton, count: model.replies, image: "bubble.left")
        Self.set(repostButton, count: model.reposts, image: model.isReposted ? "checkmark.circle" : "arrow.2.squarepath")
        Self.set(likeButton, count: model.likes, image: model.isLiked ? "heart.fill" : "heart")
    }

    private static func set(_ button: UIButton, count: Int, image: String) {
        button.setTitle(" \(count)", for: .normal)
        button.setImage(UIImage(systemName: image), for: .normal)
    }
}

extension NSAttributedString {
    /// Styles post text, colouring facets, whose offsets are UTF-8 bytes.
    static func post(text: String, facets: [Facet]? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ])
        let utf8 = text.utf8
        for facet in facets ?? [] {
            guard facet.index.byteStart < facet.index.byteEnd,
                  let start = utf8.index(utf8.startIndex, offsetBy: facet.index.byteStart, limitedBy: utf8.endIndex),
                  let end = utf8.index(utf8.startIndex, offsetBy: facet.index.byteEnd, limitedBy: utf8.endIndex)
            else { continue }
            output.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(start..<end, in: text))
        }
        return output
    }
}

extension PostCell.Model {
    init(post: Post) {
        self.init(
            headline: "\(post.author.preferredName)  @\(post.author.handle)",
            body: .post(text: post.record.text ?? "", facets: post.record.facets),
            avatar: post.author.avatar,
            media: post.isMediaCovered ? nil : post.thumbnailURL,
            note: post.note,
            showsActions: true,
            replies: post.replyCount ?? 0,
            reposts: post.repostCount ?? 0,
            likes: post.likeCount ?? 0,
            isLiked: post.viewer?.like != nil,
            isReposted: post.viewer?.repost != nil
        )
    }

    init(plain text: String, author: Author, showsHandle: Bool = true) {
        self.init(
            headline: showsHandle ? "\(author.preferredName)  @\(author.handle)" : author.preferredName,
            body: .post(text: text),
            avatar: author.avatar
        )
    }
}

enum ProfileAction {
    case follow, message, block
}

final class ProfileCell: UITableViewCell {
    static let reuseIdentifier = "profile"

    var onAction: ((ProfileAction) -> Void)?

    private let avatar = RemoteImageView(width: 72, height: 72, cornerRadius: 36)
    private let name = UILabel(style: .title2, lines: 1)
    private let bio = UILabel(style: .body)
    private let counts = UILabel(style: .footnote, color: .secondaryLabel, lines: 1)
    private lazy var followButton = UIButton(title: "Follow") { [weak self] in self?.onAction?(.follow) }
    private lazy var messageButton = UIButton(title: "Message") { [weak self] in self?.onAction?(.message) }
    private lazy var blockButton = UIButton(title: "Block") { [weak self] in self?.onAction?(.block) }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let buttons = UIStackView(axis: .horizontal, spacing: 16, arranged: [followButton, messageButton, blockButton, UIView()])
        let stack = UIStackView(axis: .vertical, spacing: 6, arranged: [avatar, name, bio, counts, buttons])
        stack.alignment = .leading
        contentView.addSubview(stack)
        stack.pinEdges(to: contentView.layoutMarginsGuide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with profile: Profile, isCurrentUser: Bool) {
        avatar.load(profile.avatar)
        name.text = profile.preferredName
        bio.text = profile.description ?? ""
        counts.text = "\(profile.followersCount ?? 0) followers · \(profile.followsCount ?? 0) following · \(profile.postsCount ?? 0) posts"
        [followButton, messageButton, blockButton].forEach { $0.isHidden = isCurrentUser }
        followButton.setTitle(profile.viewer?.following == nil ? "Follow" : "Unfollow", for: .normal)
        blockButton.setTitle(profile.viewer?.blocking == nil ? "Block" : "Unblock", for: .normal)
    }
}
