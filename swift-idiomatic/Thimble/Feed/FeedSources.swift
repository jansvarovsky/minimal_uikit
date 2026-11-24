import Foundation

enum FeedItem {
    case post(Post)
    case profile(Profile)
    case notification(NotificationItem)
    case conversation(Conversation, peer: Author)
    case message(text: String, author: Author)
}

struct FeedPage {
    var items: [FeedItem]
    var cursor: String?
}

@MainActor
protocol FeedSource {
    func page(cursor: String?) async throws -> FeedPage
}

private extension Array where Element == URLQueryItem {
    func with(cursor: String?) -> Self {
        guard let cursor else { return self }
        return self + [URLQueryItem(name: "cursor", value: cursor)]
    }
}

private func visible(_ posts: [Post]) -> [FeedItem] {
    posts.filter(\.isVisible).map(FeedItem.post)
}

struct TimelineSource: FeedSource {
    let client: BlueskyClient

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "limit", value: "30")].with(cursor: cursor)
        let response: FeedResponse = try await client.get("app.bsky.feed.getTimeline", query: query)
        return FeedPage(items: visible(response.feed.map(\.post)), cursor: response.cursor)
    }
}

struct ThreadSource: FeedSource {
    let client: BlueskyClient
    let uri: String

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "depth", value: "1"), URLQueryItem(name: "uri", value: uri)]
        let response: ThreadResponse = try await client.get("app.bsky.feed.getPostThread", query: query)
        let replies = (response.thread.replies ?? []).compactMap(\.post)
        return FeedPage(items: visible(response.thread.ancestorsAndSelf + replies), cursor: nil)
    }
}

struct AuthorFeedSource: FeedSource {
    let client: BlueskyClient
    let actor: String

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "actor", value: actor)].with(cursor: cursor)
        var header: [FeedItem] = []
        if cursor == nil, let profile: Profile = try? await client.get("app.bsky.actor.getProfile", query: [URLQueryItem(name: "actor", value: actor)]) {
            header = [.profile(profile)]
        }
        guard let response: FeedResponse = try? await client.get("app.bsky.feed.getAuthorFeed", query: query) else {
            return FeedPage(items: header, cursor: nil)
        }
        return FeedPage(items: header + visible(response.feed.map(\.post)), cursor: response.cursor)
    }
}

struct NotificationsSource: FeedSource {
    let client: BlueskyClient

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "limit", value: "40")].with(cursor: cursor)
        let response: NotificationsResponse = try await client.get("app.bsky.notification.listNotifications", query: query)
        return FeedPage(items: response.notifications.map(FeedItem.notification), cursor: response.cursor)
    }
}

struct SearchSource: FeedSource {
    let client: BlueskyClient
    var term: String?

    func page(cursor: String?) async throws -> FeedPage {
        guard let term else { return FeedPage(items: [], cursor: nil) }
        let query = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "q", value: term)].with(cursor: cursor)
        let response: SearchResponse = try await client.get("app.bsky.feed.searchPosts", query: query)
        return FeedPage(items: visible(response.posts), cursor: response.cursor)
    }
}

struct ConversationsSource: FeedSource {
    let client: BlueskyClient

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "limit", value: "40")]
        let response: ConversationsResponse = try await client.get("chat.bsky.convo.listConvos", query: query)
        let items = response.convos.compactMap { convo -> FeedItem? in
            convo.peer(of: client.did).map { .conversation(convo, peer: $0) }
        }
        return FeedPage(items: items, cursor: nil)
    }
}

struct MessagesSource: FeedSource {
    let client: BlueskyClient
    let conversation: Conversation
    let peer: Author

    func page(cursor: String?) async throws -> FeedPage {
        let query = [URLQueryItem(name: "limit", value: "60"), URLQueryItem(name: "convoId", value: conversation.id)]
        let response: MessagesResponse = try await client.get("chat.bsky.convo.getMessages", query: query)
        let items = response.messages.reversed().compactMap { message -> FeedItem? in
            guard let text = message.text else { return nil }
            let author = message.sender?.did == client.did ? Author(did: client.did, handle: "You") : peer
            return .message(text: text, author: author)
        }
        return FeedPage(items: items, cursor: nil)
    }
}
