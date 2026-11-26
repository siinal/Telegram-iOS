import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import SGSimpleSettings

// MARK: Swiftgram ghost mode

/// Whether a local input activity ("typing", "uploading photo", ...) must not be sent.
func sgGhostShouldBlockActivity(_ activity: PeerInputActivity?) -> Bool {
    let settings = SGSimpleSettings.shared
    guard settings.ghostMode else {
        return false
    }
    guard let activity = activity else {
        // A cancel is only meaningful after an activity that was sent.
        return settings.ghostBlocksTyping || settings.ghostBlocksUploadProgress
    }
    switch activity {
    case .speakingInGroupCall:
        return false
    case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
        return settings.ghostBlocksUploadProgress
    case .typingText, .recordingVoice, .playingGame, .recordingInstantVideo, .choosingSticker, .interactingWithEmoji, .seeingEmojiInteraction:
        return settings.ghostBlocksTyping
    }
}

/// Sends `account.updateStatus(offline: true)`, used to drop the online status the server
/// sets after an outgoing message.
func sgGhostSendOfflineStatus(network: Network) -> Signal<Never, NoError> {
    return network.request(Api.functions.account.updateStatus(offline: .boolTrue))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .complete()
    }
    |> ignoreValues
}

/// Called after messages are enqueued in `peerId`.
func sgGhostAfterOutgoingMessage(account: Account, peerId: PeerId) {
    let settings = SGSimpleSettings.shared
    guard settings.ghostMode else {
        return
    }
    if settings.ghostReadsAfterSend {
        let _ = sgGhostPushReadStateAfterSend(network: account.network, postbox: account.postbox, stateManager: account.stateManager, peerId: peerId).startStandalone()
    }
    if settings.ghostSendsOfflineAfterOnline {
        let network = account.network
        let offline = sgGhostSendOfflineStatus(network: network)
        let _ = (offline |> delay(2.0, queue: Queue.concurrentDefaultQueue())).startStandalone()
        let _ = (offline |> delay(8.0, queue: Queue.concurrentDefaultQueue())).startStandalone()
    }
}
