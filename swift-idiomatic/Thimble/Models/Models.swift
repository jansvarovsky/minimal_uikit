import Foundation

// MARK: - Shared

struct StrongRef: Codable {
    let uri: String
    let cid: String?
}

struct ProfileViewerState: Decodable {
    var following: String?
    var blocking: String?
    var muted: Bool?
    var blockedBy: Bool?
}

struct ContentLabel: Decodable {
    let val: String
}

struct Author: Decodable {
    var did: String?
    var handle: String
    var displayName: String?
    var avatar: String?
    var labels: [ContentLabel]?
    var viewer: ProfileViewerState?

    var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return handle
    }
}

// MARK: - Posts

struct Facet: Decodable {
    struct Index: Decodable {
        let byteStart: Int
        let byteEnd: Int
    }
    struct Feature: Decodable {
        let uri: String?
    }
    let index: Index
    let features: [Feature]
}

struct PostRecord: Decodable {
    struct Reply: Decodable {
        let root: StrongRef
    }
    var text: String?
    var facets: [Facet]?
    var reply: Reply?
}

struct Embed: Decodable {
    struct Image: Decodable {
        let thumb: String?
        let fullsize: String?
        let alt: String?
    }
    struct External: Decodable {
        let uri: String?
        let title: String?
        let thumb: String?
    }
    struct Quoted: Decodable {
        struct Value: Decodable {
            let text: String?
        }
        let value: Value?
    }
    var images: [Image]?
    var external: External?
    var playlist: String?
    var thumbnail: String?
    var record: Quoted?
}

struct PostViewerState: Decodable {
    var like: String?
    var repost: String?
}

enum ModerationDecision: Int, Comparable {
    case allow, coverMedia, remove

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(labels: [ContentLabel]?) {
        let warning: Set = ["porn", "sexual", "nudity", "graphic-media", "gore", "!warn"]
        let values = (labels ?? []).map(\.val)
        if values.contains("!hide") {
            self = .remove
        } else if values.contains(where: warning.contains) {
            self = .coverMedia
        } else {
            self = .allow
        }
    }
}

enum Engagement {
    case like, repost

    var collection: String {
        switch self {
        case .like: "app.bsky.feed.like"
        case .repost: "app.bsky.feed.repost"
        }
    }
}

struct Post: Decodable {
    let uri: String
    let cid: String?
    let author: Author
    let record: PostRecord
    var viewer: PostViewerState?
    var replyCount: Int?
    var repostCount: Int?
    var likeCount: Int?
    var labels: [ContentLabel]?
    var embed: Embed?
    var isMediaRevealed = false

    private enum CodingKeys: String, CodingKey {
        case uri, cid, author, record, viewer, replyCount, repostCount, likeCount, labels, embed
    }

    var ref: StrongRef { StrongRef(uri: uri, cid: cid) }

    var moderation: ModerationDecision {
        max(ModerationDecision(labels: labels), ModerationDecision(labels: author.labels))
    }

    var isVisible: Bool {
        guard moderation != .remove else { return false }
        let state = author.viewer
        return state?.muted != true && state?.blocking == nil && state?.blockedBy != true
    }

    var thumbnailURL: String? {
        embed?.images?.first?.thumb ?? embed?.thumbnail ?? embed?.external?.thumb
    }

    var isMediaCovered: Bool {
        thumbnailURL != nil && moderation == .coverMedia && !isMediaRevealed
    }

    var firstLink: String? {
        record.facets?.lazy.compactMap { $0.features.first?.uri }.first ?? embed?.external?.uri
    }

    var note: String {
        var lines: [String] = []
        if isMediaCovered { lines.append("Sensitive media hidden. Use More to show it.") }
        if let count = embed?.images?.count, count > 1 { lines.append("+\(count - 1) more images") }
        if embed?.playlist != nil { lines.append("▶ Video") }
        if let title = embed?.external?.title { lines.append("🔗 \(title)") }
        if let quote = embed?.record?.value?.text { lines.append("❝ \(quote)") }
        return lines.joined(separator: "\n")
    }

    func engagementURI(_ kind: Engagement) -> String? {
        switch kind {
        case .like: viewer?.like
        case .repost: viewer?.repost
        }
    }

    mutating func setEngagement(_ kind: Engagement, uri: String?, count: Int) {
        var state = viewer ?? PostViewerState()
        switch kind {
        case .like:
            state.like = uri
            likeCount = count
        case .repost:
            state.repost = uri
            repostCount = count
        }
        viewer = state
    }

    func count(of kind: Engagement) -> Int {
        switch kind {
        case .like: likeCount ?? 0
        case .repost: repostCount ?? 0
        }
    }
}

// MARK: - Feed responses

struct FeedResponse: Decodable {
    struct Item: Decodable {
        let post: Post
    }
    let feed: [Item]
    let cursor: String?
}

final class ThreadNode: Decodable {
    let post: Post?
    let parent: ThreadNode?
    let replies: [ThreadNode]?

    var ancestorsAndSelf: [Post] {
        (parent?.ancestorsAndSelf ?? []) + [post].compactMap { $0 }
    }
}

struct ThreadResponse: Decodable {
    let thread: ThreadNode
}

struct SearchResponse: Decodable {
    let posts: [Post]
    let cursor: String?
}

// MARK: - Profiles and notifications

struct Profile: Decodable {
    let did: String
    let handle: String
    var displayName: String?
    var avatar: String?
    var description: String?
    var followersCount: Int?
    var followsCount: Int?
    var postsCount: Int?
    var viewer: ProfileViewerState?

    var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return handle
    }
}

struct NotificationItem: Decodable {
    let uri: String
    let author: Author
    let reason: String
    let reasonSubject: String?
    let record: PostRecord?

    var summary: String {
        let verb = switch reason {
        case "like": "liked your post"
        case "repost": "reposted your post"
        case "follow": "followed you"
        case "reply": "replied to you"
        case "mention": "mentioned you"
        case "quote": "quoted your post"
        default: reason
        }
        guard let text = record?.text else { return verb }
        return "\(verb): \(text)"
    }

    var targetURI: String {
        guard let reasonSubject, reason != "reply", reason != "mention" else { return uri }
        return reasonSubject
    }
}

struct NotificationsResponse: Decodable {
    let notifications: [NotificationItem]
    let cursor: String?
}

// MARK: - Chat

struct Conversation: Decodable {
    struct LastMessage: Decodable {
        let text: String?
    }
    let id: String
    let members: [Author]
    let lastMessage: LastMessage?

    func peer(of did: String?) -> Author? {
        members.first { $0.did != did } ?? members.first
    }
}

struct ConversationsResponse: Decodable {
    let convos: [Conversation]
}

struct ConversationResponse: Decodable {
    let convo: Conversation
}

struct ChatMessage: Decodable {
    struct Sender: Decodable {
        let did: String
    }
    let text: String?
    let sender: Sender?
}

struct MessagesResponse: Decodable {
    let messages: [ChatMessage]
}

// MARK: - Writes

struct Blob: Codable {
    struct Link: Codable {
        let link: String
        private enum CodingKeys: String, CodingKey { case link = "$link" }
    }
    let type: String?
    let ref: Link
    let mimeType: String
    let size: Int
    private enum CodingKeys: String, CodingKey {
        case type = "$type", ref, mimeType, size
    }
}

struct UploadBlobResponse: Decodable {
    let blob: Blob
}

struct CreateRecordRequest<Record: Encodable>: Encodable {
    let repo: String
    let collection: String
    let record: Record
}

struct DeleteRecordRequest: Encodable {
    let repo: String
    let collection: String
    let rkey: String
}

struct CreatedRecord: Decodable {
    let uri: String
}

struct SubjectRecord<Subject: Encodable>: Encodable {
    let type: String
    let subject: Subject
    var createdAt = Date.now.ISO8601Format()
    private enum CodingKeys: String, CodingKey {
        case type = "$type", subject, createdAt
    }
}

struct ImagesEmbed: Encodable {
    struct Image: Encodable {
        let image: Blob
        let alt: String
    }
    let type = "app.bsky.embed.images"
    let images: [Image]
    private enum CodingKeys: String, CodingKey {
        case type = "$type", images
    }
}

struct ReplyReference: Encodable {
    let root: StrongRef
    let parent: StrongRef
}

struct NewPost: Encodable {
    let type = "app.bsky.feed.post"
    let text: String
    var createdAt = Date.now.ISO8601Format()
    let reply: ReplyReference?
    let embed: ImagesEmbed?
    private enum CodingKeys: String, CodingKey {
        case type = "$type", text, createdAt, reply, embed
    }
}

enum ReportReason: String, CaseIterable {
    case spam = "com.atproto.moderation.defs#reasonSpam"
    case harassment = "com.atproto.moderation.defs#reasonRude"
    case sexual = "com.atproto.moderation.defs#reasonSexual"
    case illegal = "com.atproto.moderation.defs#reasonViolation"
    case other = "com.atproto.moderation.defs#reasonOther"

    var title: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment"
        case .sexual: "Sexual content"
        case .illegal: "Illegal content"
        case .other: "Other"
        }
    }
}

struct ReportRequest: Encodable {
    struct Subject: Encodable {
        let type = "com.atproto.repo.strongRef"
        let uri: String
        let cid: String?
        private enum CodingKeys: String, CodingKey {
            case type = "$type", uri, cid
        }
    }
    let reasonType: String
    let subject: Subject
}

struct SendMessageRequest: Encodable {
    struct Message: Encodable {
        let text: String
    }
    let convoId: String
    let message: Message
}

struct EmptyResponse: Decodable {}
