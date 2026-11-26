import Foundation
import Postbox
import SGSimpleSettings

// MARK: Swiftgram link tracking removal

private let sgTrackingParameterNames: Set<String> = [
    "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "ysclid", "twclid", "ttclid",
    "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id",
    "vero_id", "rb_clickid", "s_cid", "ref_src", "ref_url", "si", "feature", "pp", "_openstat", "from_source"
]

private func sgIsTrackingParameter(_ name: String) -> Bool {
    let lowercased = name.lowercased()
    if lowercased.hasPrefix("utm_") {
        return true
    }
    return sgTrackingParameterNames.contains(lowercased)
}

/// Returns the url without tracking query parameters, or nil when nothing was removed.
func sgCleanTrackingUrl(_ url: String) -> String? {
    guard url.contains("?"), var components = URLComponents(string: url), let queryItems = components.queryItems, !queryItems.isEmpty else {
        return nil
    }
    let host = components.host?.lowercased() ?? ""
    let filtered = queryItems.filter { item in
        if !sgIsTrackingParameter(item.name) {
            return true
        }
        // YouTube uses "feature" and "pp" only for tracking, other sites may need them.
        let lowercased = item.name.lowercased()
        if lowercased == "feature" || lowercased == "pp" {
            return !(host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be"))
        }
        if lowercased == "si" {
            return !(host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") || host.hasSuffix("spotify.com"))
        }
        return false
    }
    if filtered.count == queryItems.count {
        return nil
    }
    components.queryItems = filtered.isEmpty ? nil : filtered
    return components.string
}

private func sgCleanTrackingLinksInText(text: String, attributes: [MessageAttribute]) -> (String, [MessageAttribute])? {
    // Rich messages carry their own layout of the text; leave them as they are.
    if attributes.contains(where: { $0 is RichTextMessageAttribute }) {
        return nil
    }
    var entities: [MessageTextEntity] = []
    var entitiesIndex: Int?
    for i in 0 ..< attributes.count {
        if let attribute = attributes[i] as? TextEntitiesMessageAttribute {
            entities = attribute.entities
            entitiesIndex = i
            break
        }
    }
    var changed = false

    // Links hidden behind text keep the text; only the url changes.
    for i in 0 ..< entities.count {
        if case let .TextUrl(url) = entities[i].type, let cleaned = sgCleanTrackingUrl(url) {
            entities[i].type = .TextUrl(url: cleaned)
            changed = true
        }
    }

    // Links written in the text: replace from the end so earlier offsets stay valid.
    let nsText = text as NSString
    var updatedText = nsText
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        let mutableText = NSMutableString(string: text)
        for match in matches.reversed() {
            let range = match.range
            if range.location == NSNotFound || range.length == 0 {
                continue
            }
            let original = nsText.substring(with: range)
            if original.lowercased().hasPrefix("mailto:") {
                continue
            }
            guard let cleaned = sgCleanTrackingUrl(original) else {
                continue
            }
            let delta = (cleaned as NSString).length - range.length
            mutableText.replaceCharacters(in: range, with: cleaned)
            changed = true
            let start = range.location
            let end = range.location + range.length
            var updatedEntities: [MessageTextEntity] = []
            for entity in entities {
                var lower = entity.range.lowerBound
                var upper = entity.range.upperBound
                if lower >= end {
                    lower += delta
                } else if lower > start {
                    lower = start
                }
                if upper >= end {
                    upper += delta
                } else if upper > start {
                    upper = start + (cleaned as NSString).length
                }
                if upper > lower {
                    updatedEntities.append(MessageTextEntity(range: lower ..< upper, type: entity.type))
                }
            }
            entities = updatedEntities
        }
        updatedText = mutableText
    }

    if !changed {
        return nil
    }
    var updatedAttributes = attributes
    if let entitiesIndex {
        updatedAttributes[entitiesIndex] = TextEntitiesMessageAttribute(entities: entities)
    }
    return (updatedText as String, updatedAttributes)
}

func sgCleanTrackingLinks(_ message: EnqueueMessage) -> EnqueueMessage {
    guard SGSimpleSettings.shared.removeLinkTracking else {
        return message
    }
    switch message {
    case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
        guard text.contains("?") || attributes.contains(where: { $0 is TextEntitiesMessageAttribute }) else {
            return message
        }
        guard let cleaned = sgCleanTrackingLinksInText(text: text, attributes: attributes) else {
            return message
        }
        let (updatedText, updatedAttributes) = cleaned
        return .message(text: updatedText, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
    case .forward:
        return message
    }
}
