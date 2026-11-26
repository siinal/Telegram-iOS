import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

// MARK: Swiftgram saved deleted and edited messages

/// Marks a message the server deleted that is kept on this device.
public final class SGDeletedMessageAttribute: MessageAttribute {
    public let date: Int32

    public init(date: Int32) {
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

/// Previous texts of an edited message, oldest first.
public final class SGEditHistoryMessageAttribute: MessageAttribute {
    public struct Entry: Equatable {
        public let text: String
        public let date: Int32

        public init(text: String, date: Int32) {
            self.text = text
            self.date = date
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    required public init(decoder: PostboxDecoder) {
        let texts = decoder.decodeStringArrayForKey("t")
        let dates = decoder.decodeInt32ArrayForKey("d")
        var entries: [Entry] = []
        for i in 0 ..< min(texts.count, dates.count) {
            entries.append(Entry(text: texts[i], date: dates[i]))
        }
        self.entries = entries
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeStringArray(self.entries.map { $0.text }, forKey: "t")
        encoder.encodeInt32Array(self.entries.map { $0.date }, forKey: "d")
    }
}

public extension Message {
    /// When the server deleted this message, if it is kept on this device.
    var sgDeletedDate: Int32? {
        for attribute in self.attributes {
            if let attribute = attribute as? SGDeletedMessageAttribute {
                return attribute.date
            }
        }
        return nil
    }

    var sgEditHistory: [SGEditHistoryMessageAttribute.Entry] {
        for attribute in self.attributes {
            if let attribute = attribute as? SGEditHistoryMessageAttribute {
                return attribute.entries
            }
        }
        return []
    }
}

func sgIsKeptDeletedMessage(transaction: Transaction, id: MessageId) -> Bool {
    guard let message = transaction.getMessage(id) else {
        return false
    }
    return message.sgDeletedDate != nil
}

private func sgShouldKeepDeletedMessage(transaction: Transaction, message: Message) -> Bool {
    if message.id.namespace != Namespaces.Message.Cloud {
        return false
    }
    if sgIsSavingExcluded(message.id.peerId) {
        return false
    }
    if let user = transaction.getPeer(message.id.peerId) as? TelegramUser, user.botInfo != nil {
        return SGSimpleSettings.shared.saveDeletedForBots
    }
    return true
}

/// Called with the ids the server deleted. Keeps the messages it can, marked as deleted, and returns the ids
/// that must still be deleted.
func sgKeepDeletedMessages(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    guard SGSimpleSettings.shared.saveDeletedMessages else {
        return ids
    }
    let timestamp = Int32(Date().timeIntervalSince1970)
    var remaining: [MessageId] = []
    for id in ids {
        guard let message = transaction.getMessage(id), sgShouldKeepDeletedMessage(transaction: transaction, message: message) else {
            remaining.append(id)
            continue
        }
        if message.sgDeletedDate != nil {
            continue
        }
        transaction.updateMessage(id, update: { currentMessage in
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
            }
            var attributes = currentMessage.attributes
            attributes.append(SGDeletedMessageAttribute(date: timestamp))
            return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
        })
    }
    return remaining
}

/// The same for global ids (private chats and basic groups). Returns the global ids that must still be deleted.
func sgKeepDeletedMessagesWithGlobalIds(transaction: Transaction, ids: [Int32]) -> [Int32] {
    guard SGSimpleSettings.shared.saveDeletedMessages else {
        return ids
    }
    var remaining: [Int32] = []
    for globalId in ids {
        guard let messageId = transaction.messageIdsForGlobalIds([globalId]).first else {
            remaining.append(globalId)
            continue
        }
        if !sgKeepDeletedMessages(transaction: transaction, ids: [messageId]).isEmpty {
            remaining.append(globalId)
        }
    }
    return remaining
}

/// Adds the previous text of an edited message to its edit history.
func sgAddEditHistory(previous previousMessage: Message, updated message: StoreMessage) -> StoreMessage {
    guard SGSimpleSettings.shared.saveEditHistory, !sgIsSavingExcluded(previousMessage.id.peerId) else {
        return message
    }
    if previousMessage.text == message.text || previousMessage.text.isEmpty {
        return message
    }
    var entries = previousMessage.sgEditHistory
    entries.append(SGEditHistoryMessageAttribute.Entry(text: previousMessage.text, date: previousMessage.editedTime ?? previousMessage.timestamp))
    if entries.count > 50 {
        entries.removeFirst(entries.count - 50)
    }
    var attributes = message.attributes.filter { !($0 is SGEditHistoryMessageAttribute) }
    attributes.append(SGEditHistoryMessageAttribute(entries: entries))
    return message.withUpdatedAttributes(attributes)
}

/// A saved deleted message found by the search across chats.
public struct SGDeletedMessageItem {
    public let chatTitle: String
    public let authorTitle: String
    public let timestamp: Int32
    public let deletedDate: Int32
    public let text: String
    public let hasMedia: Bool
}

/// Finds saved deleted messages in the chat list (main list and archive), newest chats first.
/// Bounded so a large database does not hold the Postbox queue for long.
public func sgCollectDeletedMessages(account: Account, maxChats: Int = 300, maxMessagesPerChat: Int = 3000, maxResults: Int = 2000) -> Signal<[SGDeletedMessageItem], NoError> {
    return account.postbox.transaction { transaction -> [SGDeletedMessageItem] in
        var result: [SGDeletedMessageItem] = []
        var peers: [Peer] = []
        peers.append(contentsOf: transaction.getChatListPeers(groupId: .root, filterPredicate: nil, additionalFilter: nil))
        peers.append(contentsOf: transaction.getChatListPeers(groupId: Namespaces.PeerGroup.archive, filterPredicate: nil, additionalFilter: nil))
        for peer in peers.prefix(maxChats) {
            if result.count >= maxResults {
                break
            }
            var scanned = 0
            transaction.withAllMessages(peerId: peer.id, reversed: true, { message in
                scanned += 1
                if scanned > maxMessagesPerChat || result.count >= maxResults {
                    return false
                }
                if let deletedDate = message.sgDeletedDate {
                    result.append(SGDeletedMessageItem(
                        chatTitle: peer.debugDisplayTitle,
                        authorTitle: message.author?.debugDisplayTitle ?? "",
                        timestamp: message.timestamp,
                        deletedDate: deletedDate,
                        text: message.text,
                        hasMedia: !message.media.isEmpty
                    ))
                }
                return true
            })
        }
        result.sort(by: { $0.deletedDate > $1.deletedDate })
        return result
    }
}

// MARK: Chats where deleted and edited messages are not saved

public func sgIsSavingExcluded(_ peerId: PeerId) -> Bool {
    let raw = SGSimpleSettings.shared.saveExcludedPeerIds
    if raw.isEmpty {
        return false
    }
    return raw.contains(String(peerId.toInt64()))
}

public func sgSetSavingExcluded(_ peerId: PeerId, _ value: Bool) {
    var raw = SGSimpleSettings.shared.saveExcludedPeerIds
    let key = String(peerId.toInt64())
    raw.removeAll(where: { $0 == key })
    if value {
        raw.append(key)
    }
    SGSimpleSettings.shared.saveExcludedPeerIds = raw
}
