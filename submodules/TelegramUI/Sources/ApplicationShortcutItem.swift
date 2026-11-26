import Foundation
import UIKit
import TelegramPresentationData
import DeviceAccess
import SGSimpleSettings

enum ApplicationShortcutItemType: String {
    case search
    case compose
    case camera
    case savedMessages
    case account
    case appIcon
    case sgGhostMode = "sgGhostMode"
}

struct ApplicationShortcutItem: Equatable {
    let type: ApplicationShortcutItemType
    let title: String
    let subtitle: String?
}

@available(iOS 9.1, *)
extension ApplicationShortcutItem {
    func shortcutItem() -> UIApplicationShortcutItem {
        let icon: UIApplicationShortcutIcon
        switch self.type {
            case .search:
                icon = UIApplicationShortcutIcon(type: .search)
            case .compose:
                icon = UIApplicationShortcutIcon(type: .compose)
            case .camera:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Camera")
            case .savedMessages:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/SavedMessages")
            case .account:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Account")
            case .appIcon:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/AppIcon")
            case .sgGhostMode:
                icon = UIApplicationShortcutIcon(systemImageName: "eye.slash")
        }
        return UIApplicationShortcutItem(type: self.type.rawValue, localizedTitle: self.title, localizedSubtitle: self.subtitle, icon: icon, userInfo: nil)
    }
}

/// The ghost mode shortcut, titled with the state it is in.
func sgGhostShortcutItem(strings: PresentationStrings) -> ApplicationShortcutItem {
    let lang = strings.baseLanguageCode
    let isRu = lang == "ru" || lang == "uk" || lang == "be"
    let isOn = SGSimpleSettings.shared.ghostMode
    let subtitle: String
    if isOn {
        subtitle = isRu ? "Включён — нажмите, чтобы выключить" : "On — tap to turn off"
    } else {
        subtitle = isRu ? "Выключен — нажмите, чтобы включить" : "Off — tap to turn on"
    }
    return ApplicationShortcutItem(type: .sgGhostMode, title: isRu ? "Режим призрака" : "Ghost Mode", subtitle: subtitle)
}

func applicationShortcutItems(strings: PresentationStrings, otherAccountName: String?) -> [ApplicationShortcutItem] {
    if let otherAccountName = otherAccountName {
        return [
            sgGhostShortcutItem(strings: strings),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .savedMessages, title: strings.Conversation_SavedMessages, subtitle: nil),
            ApplicationShortcutItem(type: .account, title: strings.Shortcut_SwitchAccount, subtitle: otherAccountName)
        ]
    } else {
        return [
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .savedMessages, title: strings.Conversation_SavedMessages, subtitle: nil),
            sgGhostShortcutItem(strings: strings)
        ]
    }
}
