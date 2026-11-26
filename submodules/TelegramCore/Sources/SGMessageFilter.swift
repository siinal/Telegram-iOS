import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

// MARK: Swiftgram message filters

private final class SGCompiledFilters {
    let patterns: [String]
    let expressions: [NSRegularExpression]

    init(patterns: [String]) {
        self.patterns = patterns
        var expressions: [NSRegularExpression] = []
        for pattern in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                expressions.append(expression)
            }
        }
        self.expressions = expressions
    }
}

private let sgCompiledFilters = Atomic<SGCompiledFilters?>(value: nil)

private func sgCurrentFilterExpressions() -> [NSRegularExpression] {
    let patterns = SGSimpleSettings.shared.filterPatterns
    return sgCompiledFilters.modify { current in
        if let current, current.patterns == patterns {
            return current
        }
        return SGCompiledFilters(patterns: patterns)
    }?.expressions ?? []
}

/// Checks a regular expression the way the filters use it. Returns an error description for an invalid one.
public func sgValidateFilterPattern(_ pattern: String) -> String? {
    do {
        let _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return nil
    } catch {
        return error.localizedDescription
    }
}

/// Blocked peers of each account, loaded from the server once per launch and kept up to date while it runs.
public final class SGBlockedPeers {
    public static let shared = SGBlockedPeers()

    private let ids = Atomic<[PeerId: Set<PeerId>]>(value: [:])
    private var contexts: [PeerId: BlockedPeersContext] = [:]
    private var disposables: [PeerId: Disposable] = [:]

    private init() {
    }

    /// Main queue only.
    public func start(account: Account) {
        let accountPeerId = account.peerId
        if self.contexts[accountPeerId] != nil {
            return
        }
        let context = BlockedPeersContext(account: account, subject: .blocked)
        self.contexts[accountPeerId] = context
        var pageRequests = 0
        self.disposables[accountPeerId] = (context.state
        |> deliverOnMainQueue).start(next: { [weak self, weak context] state in
            guard let self else {
                return
            }
            let peerIds = Set(state.peers.map { $0.peerId })
            let _ = self.ids.modify { current in
                var current = current
                current[accountPeerId] = peerIds
                return current
            }
            if state.canLoadMore && !state.isLoadingMore && pageRequests < 50 {
                pageRequests += 1
                DispatchQueue.main.async {
                    context?.loadMore()
                }
            }
        })
    }

    public func isBlocked(accountPeerId: PeerId, peerId: PeerId) -> Bool {
        return self.ids.with { $0[accountPeerId]?.contains(peerId) ?? false }
    }
}

// MARK: Swiftgram shadow ban

private let sgShadowBanCache = Atomic<(raw: [String], ids: Set<Int64>)?>(value: nil)

private func sgShadowBannedIds() -> Set<Int64> {
    let raw = SGSimpleSettings.shared.shadowBannedPeerIds
    return sgShadowBanCache.modify { current in
        if let current, current.raw == raw {
            return current
        }
        return (raw: raw, ids: Set(raw.compactMap { Int64($0) }))
    }?.ids ?? []
}

public func sgIsShadowBanned(_ peerId: PeerId) -> Bool {
    return sgShadowBannedIds().contains(peerId.toInt64())
}

public func sgSetShadowBanned(_ peerId: PeerId, _ value: Bool) {
    var raw = SGSimpleSettings.shared.shadowBannedPeerIds
    let key = String(peerId.toInt64())
    raw.removeAll(where: { $0 == key })
    if value {
        raw.append(key)
    }
    SGSimpleSettings.shared.shadowBannedPeerIds = raw
}

/// Whether an incoming message is hidden from the chat by the filters.
public func sgIsMessageFiltered(_ message: Message, accountPeerId: PeerId) -> Bool {
    let settings = SGSimpleSettings.shared
    if settings.hideMemberServiceMessages {
        for media in message.media {
            if let action = media as? TelegramMediaAction {
                switch action.action {
                case .addedMembers, .removedMembers, .joinedByLink, .joinedByRequest:
                    return true
                default:
                    break
                }
            }
        }
    }
    if !message.flags.contains(.Incoming) || message.id.peerId == accountPeerId {
        return false
    }
    // Shadow-banned users are hidden in groups and channels whether the filters are on or not.
    let isPrivate = message.id.peerId.namespace == Namespaces.Peer.CloudUser || message.id.peerId.namespace == Namespaces.Peer.SecretChat
    if !isPrivate, let authorId = message.author?.id, authorId != accountPeerId, sgIsShadowBanned(authorId) {
        return true
    }
    guard settings.filterEnabled else {
        return false
    }
    if message.media.contains(where: { $0 is TelegramMediaAction }) {
        return false
    }
    let isPrivateChat = message.id.peerId.namespace == Namespaces.Peer.CloudUser || message.id.peerId.namespace == Namespaces.Peer.SecretChat
    if isPrivateChat && !settings.filterInPrivateChats {
        return false
    }
    if settings.filterHideBlocked, !isPrivateChat, let authorId = message.author?.id, authorId != accountPeerId {
        if SGBlockedPeers.shared.isBlocked(accountPeerId: accountPeerId, peerId: authorId) {
            return true
        }
    }
    if message.text.isEmpty {
        return false
    }
    let expressions = sgCurrentFilterExpressions()
    if expressions.isEmpty {
        return false
    }
    let range = NSRange(location: 0, length: (message.text as NSString).length)
    for expression in expressions {
        if expression.firstMatch(in: message.text, options: [], range: range) != nil {
            return true
        }
    }
    return false
}

/// The first pattern that matches the text, for checking patterns in settings.
public func sgFirstMatchingFilterPattern(_ text: String, patterns: [String]) -> String? {
    let range = NSRange(location: 0, length: (text as NSString).length)
    for pattern in patterns {
        if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), expression.firstMatch(in: text, options: [], range: range) != nil {
            return pattern
        }
    }
    return nil
}

// MARK: Swiftgram hidden chats

private let sgHiddenChatsCache = Atomic<(raw: [String], ids: Set<Int64>)?>(value: nil)

private func sgHiddenChatIdSet() -> Set<Int64> {
    let raw = SGSimpleSettings.shared.hiddenChatPeerIds
    if raw.isEmpty {
        return []
    }
    return sgHiddenChatsCache.modify { current in
        if let current, current.raw == raw {
            return current
        }
        return (raw: raw, ids: Set(raw.compactMap { Int64($0) }))
    }?.ids ?? []
}

/// Whether the chat is hidden from the chat list.
public func sgIsHiddenChat(_ peerId: PeerId) -> Bool {
    return sgHiddenChatIdSet().contains(peerId.toInt64())
}

public func sgSetHiddenChat(_ peerId: PeerId, _ value: Bool) {
    var raw = SGSimpleSettings.shared.hiddenChatPeerIds
    let key = String(peerId.toInt64())
    raw.removeAll(where: { $0 == key })
    if value {
        raw.append(key)
    }
    SGSimpleSettings.shared.hiddenChatPeerIds = raw
}

public func sgHiddenChatPeerIds() -> [PeerId] {
    return SGSimpleSettings.shared.hiddenChatPeerIds.compactMap { Int64($0) }.map { PeerId($0) }
}
