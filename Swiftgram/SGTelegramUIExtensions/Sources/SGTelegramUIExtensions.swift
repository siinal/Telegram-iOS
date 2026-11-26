import SGSimpleSettings
import SGDebugUI
import SGSettingsUI
import SGStrings
import UndoUI
//
import AccountContext
import LocalizedPeerData
import ContactListUI
import ContextUI
import Display
import Foundation
import OverlayStatusController
import Postbox
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit
import ChatControllerInteraction
import ChatPresentationInterfaceState

func sgHandleInternalUrlRoute(context: AccountContext, parsedUrl: URL, navigationController: NavigationController?) -> Bool {
    guard let path = parsedUrl.pathComponents.last else {
        return false
    }
    switch path {
    case "debug":
        if let debugController = context.sharedContext.makeDebugSettingsController(context: context) {
            navigationController?.pushViewController(debugController)
            return true
        }
    case "sgdebug", "sg_debug":
        navigationController?.pushViewController(sgDebugController(context: context))
        return true
    case "settings":
        navigationController?.pushViewController(sgSettingsController(context: context))
        return true
    case "ios_settings":
        context.sharedContext.applicationBindings.openSettings()
        return true
    case "contacts":
        if let lastViewController = navigationController?.viewControllers.last as? ViewController {
            lastViewController.present(ContactsController(context: context), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }
        return true
    case "pro", "premium", "buy":
        if context.sharedContext.immediateSGStatus.status > 1 {
            navigationController?.pushViewController(context.sharedContext.makeSGProController(context: context))
        } else if let lastViewController = navigationController?.viewControllers.last as? ViewController {
            if let payWallController = context.sharedContext.makeSGPayWallController(context: context) {
                lastViewController.present(payWallController, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            } else {
                lastViewController.present(context.sharedContext.makeSGUpdateIOSController(), animated: true)
            }
        }
    case "restart":
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        context.sharedContext.presentGlobalController(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil, text: "Common.RestartRequired".i18n(lang), timeout: nil, customUndoText: "Common.RestartNow".i18n(lang)),
                elevatedLayout: false,
                action: { action in if action == .undo { exit(0) }; return true }
            ),
            nil
        )
    case "restore_purchases", "pro_restore", "validate", "restore":
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        context.sharedContext.presentGlobalController(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil, text: "PayWall.Button.Restoring".i18n(lang), timeout: nil, customUndoText: nil),
                elevatedLayout: false,
                action: { _ in return false }
            ),
            nil
        )
        context.sharedContext.SGIAP?.restorePurchases {}
    default:
        break
    }
    return false
}

func sgCanRevealContent(messages: [EngineRawMessage], context: AccountContext, copyProtectionEnabled: Bool) -> Bool {
    guard !copyProtectionEnabled else {
        return false
    }
    for message in messages {
        if message.canRevealContent(contentSettings: context.currentContentSettings.with { $0 }) {
            return true
        }
    }
    return false
}

enum SGContextMenuActionFactory {
    case json(controllerInteraction: ChatControllerInteraction, context: AccountContext)
    case saveToCloud(interfaceInteraction: ChatPanelInterfaceInteraction, selectAll: Bool, isImage: Bool, messages: [EngineRawMessage])
    case hideForwardName(interfaceInteraction: ChatPanelInterfaceInteraction, selectAll: Bool, isImage: Bool, messages: [EngineRawMessage])
    case editHistory(controllerInteraction: ChatControllerInteraction, context: AccountContext)
    case lyrics(controllerInteraction: ChatControllerInteraction, context: AccountContext, title: String, performer: String?)
    case askAI(controllerInteraction: ChatControllerInteraction, context: AccountContext, mode: Int)
    case ghostMarkRead(context: AccountContext)
    case messageShot(context: AccountContext, view: () -> UIView?)
    case deletedList(controllerInteraction: ChatControllerInteraction, context: AccountContext)
    case shadowBan(authorId: EnginePeer.Id, authorName: String)
    case ghostReadException(context: AccountContext)
    case calculate(controllerInteraction: ChatControllerInteraction, context: AccountContext)
    case copyIds(context: AccountContext)
    case exportChat(context: AccountContext)
    case hideChat(context: AccountContext)
    case clearDeleted(context: AccountContext)
}

/// Draws a message bubble on the chat background colour, with a margin.
func sgRenderMessageShot(view: UIView, backgroundColor: UIColor) -> UIImage? {
    let size = view.bounds.size
    if size.width < 1.0 || size.height < 1.0 {
        return nil
    }
    let inset: CGFloat = 16.0
    let format = UIGraphicsImageRendererFormat()
    format.scale = max(UIScreen.main.scale, 2.0)
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width + inset * 2.0, height: size.height + inset * 2.0), format: format)
    return renderer.image { rendererContext in
        backgroundColor.setFill()
        rendererContext.fill(CGRect(origin: .zero, size: CGSize(width: size.width + inset * 2.0, height: size.height + inset * 2.0)))
        let drawn = view.drawHierarchy(in: CGRect(origin: CGPoint(x: inset, y: inset), size: size), afterScreenUpdates: false)
        if !drawn {
            rendererContext.cgContext.translateBy(x: inset, y: inset)
            view.layer.render(in: rendererContext.cgContext)
        }
    }
}

/// Title and performer of a music file in the message, for looking up its lyrics.
func sgMusicInfo(message: EngineRawMessage) -> (title: String, performer: String?)? {
    for media in message.media {
        guard let file = media as? TelegramMediaFile, file.isMusic else {
            continue
        }
        for attribute in file.attributes {
            if case let .Audio(_, _, rawTitle, performer, _) = attribute, let title = rawTitle, !title.isEmpty {
                return (title, performer)
            }
        }
    }
    return nil
}

func sgMakeContextMenuAction(_ action: SGContextMenuActionFactory, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem {
    switch action {
    case let .json(controllerInteraction, context):
        return .action(ContextMenuActionItem(text: "JSON", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Settings"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            showMessageJson(controllerInteraction: controllerInteraction, chatPresentationInterfaceState: chatPresentationInterfaceState, message: message, context: context)
            f(.default)
        }))
    case let .saveToCloud(interfaceInteraction, selectAll, isImage, messages):
        return .action(ContextMenuActionItem(text: i18n("ContextMenu.SaveToCloud", chatPresentationInterfaceState.strings.baseLanguageCode), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Fave"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            interfaceInteraction.forwardMessages(selectAll || isImage ? messages : [message], "forwardMessagesToCloud")
            f(.dismissWithoutContent)
        }))
    case let .hideForwardName(interfaceInteraction, selectAll, isImage, messages):
        return .action(ContextMenuActionItem(text: chatPresentationInterfaceState.strings.NotificationSettings_Stories_CompactHideName, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            interfaceInteraction.forwardMessages(selectAll || isImage ? messages : [message], "forwardMessagesWithNoNames")
            f(.dismissWithoutContent)
        }))
    case let .editHistory(controllerInteraction, context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let title = isRu ? "История изменений" : "Edit History"
        return .action(ContextMenuActionItem(text: title, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            var parts: [String] = []
            for entry in message.sgEditHistory {
                let dateString = formatter.string(from: Date(timeIntervalSince1970: Double(entry.date)))
                parts.append(dateString + "\n" + entry.text)
            }
            let currentDate = message.editedTime ?? message.timestamp
            let currentLabel = isRu ? "сейчас" : "current"
            let currentDateString = formatter.string(from: Date(timeIntervalSince1970: Double(currentDate)))
            parts.append(currentDateString + " (" + currentLabel + ")\n" + message.text)
            let model = SGTextViewerModel(text: parts.reversed().joined(separator: "\n\n— — —\n\n"), isLoading: false)
            controllerInteraction.navigationController()?.pushViewController(sgTextViewerController(context: context, title: title, model: model))
        }))
    case let .lyrics(controllerInteraction, context, title, performer):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        return .action(ContextMenuActionItem(text: isRu ? "Текст песни" : "Lyrics", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let model = SGTextViewerModel(text: "", isLoading: true)
            let viewerTitle = [performer, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            controllerInteraction.navigationController()?.pushViewController(sgTextViewerController(context: context, title: viewerTitle, model: model))
            sgFetchLyrics(title: title, artist: performer, completion: { lyrics in
                model.finish(text: lyrics ?? (isRu ? "Текст не найден на lrclib.net." : "No lyrics found on lrclib.net."))
            })
        }))
    case let .askAI(controllerInteraction, context, mode):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let title: String
        let instruction: String
        if mode == 3 {
            title = isRu ? "ИИ: свой запрос" : "AI: Custom Prompt"
            instruction = SGSimpleSettings.shared.aiCustomPrompt
        } else if mode == 2 {
            title = isRu ? "ИИ: предложить ответ" : "AI: Suggest Reply"
            instruction = isRu ? "Предложи три коротких варианта ответа на сообщение пользователя, на языке сообщения. Каждый вариант с новой строки, без пояснений." : "Suggest three short replies to the user's message, in the message's language. One per line, no explanations."
        } else if mode == 1 {
            title = isRu ? "ИИ: перевести" : "AI: Translate"
            instruction = isRu ? "Переведи сообщение пользователя на русский язык. Ответь только переводом." : "Translate the user's message into English. Reply with the translation only."
        } else {
            title = isRu ? "ИИ: пересказать" : "AI: Summarize"
            instruction = isRu ? "Кратко перескажи сообщение пользователя на русском языке и объясни непонятные места." : "Briefly summarize the user's message in English and explain anything unclear."
        }
        return .action(ContextMenuActionItem(text: title, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let model = SGTextViewerModel(text: "", isLoading: true)
            controllerInteraction.navigationController()?.pushViewController(sgTextViewerController(context: context, title: title, model: model))
            sgAskAI(instruction: instruction, text: message.text, completion: { result in
                switch result {
                case let .success(answer):
                    model.finish(text: answer)
                case let .failure(error):
                    model.finish(text: (isRu ? "Ошибка: " : "Error: ") + error.localizedDescription)
                }
            })
        }))
    case let .messageShot(context, view):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        return .action(ContextMenuActionItem(text: isRu ? "Скриншот сообщения" : "Message Shot", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Share"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            let backgroundColor = chatPresentationInterfaceState.theme.list.plainBackgroundColor
            let image = view().flatMap { sgRenderMessageShot(view: $0, backgroundColor: backgroundColor) }
            f(.default)
            guard let image else {
                return
            }
            let activityController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            Queue.mainQueue().after(0.3) {
                context.sharedContext.mainWindow?.presentNative(activityController)
            }
        }))
    case let .deletedList(controllerInteraction, context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let title = isRu ? "Удалённые в этом чате" : "Deleted in This Chat"
        let peerId = message.id.peerId
        return .action(ContextMenuActionItem(text: title, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let model = SGTextViewerModel(text: "", isLoading: true)
            controllerInteraction.navigationController()?.pushViewController(sgTextViewerController(context: context, title: title, model: model))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let _ = (context.account.postbox.transaction { transaction -> [String] in
                var result: [String] = []
                transaction.withAllMessages(peerId: peerId, reversed: true, { searchMessage in
                    if result.count >= 1000 {
                        return false
                    }
                    if let deletedDate = searchMessage.sgDeletedDate {
                        let author = searchMessage.author.flatMap { EnginePeer($0).displayTitle(strings: chatPresentationInterfaceState.strings, displayOrder: chatPresentationInterfaceState.nameDisplayOrder) } ?? ""
                        let sent = formatter.string(from: Date(timeIntervalSince1970: Double(searchMessage.timestamp)))
                        let deleted = formatter.string(from: Date(timeIntervalSince1970: Double(deletedDate)))
                        var body = searchMessage.text
                        if body.isEmpty {
                            body = searchMessage.media.isEmpty ? "—" : (isRu ? "[медиа]" : "[media]")
                        }
                        result.append(author + " · " + sent + "\n" + (isRu ? "удалено " : "deleted ") + deleted + "\n" + body)
                    }
                    return true
                })
                return result
            }
            |> deliverOnMainQueue).start(next: { items in
                model.finish(text: items.isEmpty ? (isRu ? "В этом чате нет сохранённых удалённых сообщений." : "No saved deleted messages in this chat.") : items.joined(separator: "\n\n— — —\n\n"))
            })
        }))
    case let .shadowBan(authorId, authorName):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let isBanned = sgIsShadowBanned(authorId)
        let text: String
        if isBanned {
            text = isRu ? "Показывать \(authorName)" : "Show \(authorName)"
        } else {
            text = isRu ? "Скрыть \(authorName) (тень)" : "Hide \(authorName) (Shadow Ban)"
        }
        return .action(ContextMenuActionItem(text: text, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: isBanned ? "Chat/Context Menu/Eye" : "Chat/Context Menu/Ban"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            sgSetShadowBanned(authorId, !isBanned)
        }))
    case let .hideChat(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let peerId = message.id.peerId
        let isHidden = sgIsHiddenChat(peerId)
        return .action(ContextMenuActionItem(text: isHidden ? (isRu ? "Вернуть чат в список" : "Unhide This Chat") : (isRu ? "Скрыть этот чат" : "Hide This Chat"), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: isHidden ? "Chat/Context Menu/Eye" : "Chat/Context Menu/EyeLocked"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            sgSetHiddenChat(peerId, !isHidden)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let text: String
            if isHidden {
                text = isRu ? "Чат снова в списке чатов" : "The chat is back in the chat list"
            } else {
                text = isRu ? "Чат скрыт. Найти его: Настройки → Swiftgram → Скрытые чаты" : "Chat hidden. Find it in Settings → Swiftgram → Hidden Chats"
            }
            context.sharedContext.presentGlobalController(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), nil)
        }))
    case let .exportChat(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let peerId = message.id.peerId
        let strings = chatPresentationInterfaceState.strings
        let nameDisplayOrder = chatPresentationInterfaceState.nameDisplayOrder
        return .action(ContextMenuActionItem(text: isRu ? "Экспорт чата в TXT" : "Export Chat as TXT", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/File"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            context.sharedContext.presentGlobalController(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: isRu ? "Готовлю файл…" : "Preparing file…", timeout: 2.0, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), nil)
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yyyy HH:mm"
            let _ = (context.account.postbox.transaction { transaction -> String in
                var lines: [String] = []
                var count = 0
                transaction.withAllMessages(peerId: peerId, reversed: false, { item in
                    if count >= 50000 {
                        return false
                    }
                    count += 1
                    let author = item.author.flatMap { EnginePeer($0).displayTitle(strings: strings, displayOrder: nameDisplayOrder) } ?? ""
                    var mediaLabel: String?
                    for media in item.media {
                        if media is TelegramMediaAction {
                            mediaLabel = isRu ? "[служебное сообщение]" : "[service message]"
                        } else if media is TelegramMediaImage {
                            mediaLabel = isRu ? "[фото]" : "[photo]"
                        } else if let file = media as? TelegramMediaFile {
                            if file.isVoice {
                                mediaLabel = isRu ? "[голосовое]" : "[voice]"
                            } else if file.isInstantVideo {
                                mediaLabel = isRu ? "[кружок]" : "[video message]"
                            } else if file.isSticker || file.isAnimatedSticker {
                                mediaLabel = isRu ? "[стикер]" : "[sticker]"
                            } else if file.isVideo {
                                mediaLabel = isRu ? "[видео]" : "[video]"
                            } else {
                                mediaLabel = "[" + (file.fileName ?? (isRu ? "файл" : "file")) + "]"
                            }
                        } else if mediaLabel == nil {
                            mediaLabel = isRu ? "[медиа]" : "[media]"
                        }
                    }
                    var body = item.text
                    if let mediaLabel {
                        body = body.isEmpty ? mediaLabel : mediaLabel + " " + body
                    }
                    var line = "[" + formatter.string(from: Date(timeIntervalSince1970: Double(item.timestamp))) + "] " + author + ": " + body
                    if item.sgDeletedDate != nil {
                        line += isRu ? " (удалено)" : " (deleted)"
                    }
                    lines.append(line)
                    return true
                })
                return lines.joined(separator: "\n")
            }
            |> deliverOnMainQueue).start(next: { text in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-" + String(peerId.id._internalGetInt64Value()) + ".txt")
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    return
                }
                let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                context.sharedContext.mainWindow?.presentNative(activityController)
            })
        }))
    case let .clearDeleted(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let peerId = message.id.peerId
        return .action(ContextMenuActionItem(text: isRu ? "Стереть сохранённые удалённые" : "Erase Saved Deleted", textColor: .destructive, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
        }, action: { _, f in
            f(.default)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let mediaBox = context.account.postbox.mediaBox
            context.sharedContext.presentGlobalController(textAlertController(context: context, title: nil, text: isRu ? "Стереть с устройства все сохранённые удалённые сообщения этого чата? Это нельзя отменить." : "Erase all saved deleted messages of this chat from this device? This cannot be undone.", actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: isRu ? "Стереть" : "Erase", action: {
                    let _ = context.account.postbox.transaction({ transaction -> Void in
                        var ids: [MessageId] = []
                        transaction.withAllMessages(peerId: peerId, reversed: true, { item in
                            if item.sgDeletedDate != nil {
                                ids.append(item.id)
                            }
                            return true
                        })
                        if !ids.isEmpty {
                            _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids)
                        }
                    }).start()
                })
            ]), nil)
        }))
    case let .copyIds(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        return .action(ContextMenuActionItem(text: isRu ? "Копировать ID" : "Copy IDs", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            var lines: [String] = []
            lines.append((isRu ? "Сообщение: " : "Message: ") + String(message.id.id))
            lines.append((isRu ? "Чат: " : "Chat: ") + String(message.id.peerId.id._internalGetInt64Value()))
            if let author = message.author {
                lines.append((isRu ? "Автор: " : "Author: ") + String(author.id.id._internalGetInt64Value()))
            }
            UIPasteboard.general.string = lines.joined(separator: "\n")
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            context.sharedContext.presentGlobalController(UndoOverlayController(presentationData: presentationData, content: .copy(text: isRu ? "ID скопированы" : "IDs copied"), elevatedLayout: false, action: { _ in return false }), nil)
        }))
    case let .calculate(controllerInteraction, context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        return .action(ContextMenuActionItem(text: isRu ? "Посчитать" : "Calculate", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Statistics"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let expression = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = sgEvaluateExpression(expression) else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let resultText = sgFormatCalculation(value)
            controllerInteraction.presentController(textAlertController(context: context, title: resultText, text: expression + " =" + "\n" + resultText, actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Conversation_ContextMenuCopy, action: {
                    UIPasteboard.general.string = resultText
                }),
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]), nil)
        }))
    case let .ghostReadException(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        let peerId = message.id.peerId
        let isException = sgGhostIsReadException(peerId)
        let text: String
        if isException {
            text = isRu ? "Призрак: не читать этот чат" : "Ghost: Don't Read This Chat"
        } else {
            text = isRu ? "Призрак: читать этот чат" : "Ghost: Read This Chat"
        }
        return .action(ContextMenuActionItem(text: text, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: isException ? "Chat/Context Menu/EyeLocked" : "Chat/Context Menu/Eye"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            sgGhostSetReadException(peerId, !isException)
            if !isException {
                sgGhostMarkChatRead(account: context.account, peerId: peerId)
            }
        }))
    case let .ghostMarkRead(context):
        let lang = chatPresentationInterfaceState.strings.baseLanguageCode
        let isRu = lang == "ru" || lang == "uk" || lang == "be"
        return .action(ContextMenuActionItem(text: isRu ? "Прочитать (призрак)" : "Mark as Read (Ghost)", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            sgGhostMarkChatRead(account: context.account, peerId: message.id.peerId)
        }))
    }
}

func sgMakeSelectFromUserContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, controllerInteraction: ChatControllerInteraction, interfaceInteraction: ChatPanelInterfaceInteraction, message: EngineRawMessage) -> ContextMenuItem? {
    guard let authorId = message.author?.id else {
        return nil
    }
    return .action(ContextMenuActionItem(text: i18n("ContextMenu.SelectFromUser", chatPresentationInterfaceState.strings.baseLanguageCode), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/SelectAll"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        let progressSignal = Signal<Never, NoError> { _ in
            let overlayController = OverlayStatusController(theme: chatPresentationInterfaceState.theme, type: .loading(cancelled: nil))
            controllerInteraction.presentGlobalOverlayController(overlayController, nil)
            return ActionDisposable { [weak overlayController] in
                Queue.mainQueue().async {
                    overlayController?.dismiss()
                }
            }
        }
        |> runOn(Queue.mainQueue())
        |> delay(0.2, queue: Queue.mainQueue())
        let progressDisposable = progressSignal.start()
        let _ = (context.account.postbox.transaction { transaction -> [MessageId] in
            let limit = 500
            var result: [MessageId] = []
            let needThreadIdFilter: Bool
            let searchThreadId: Int64?
            switch chatPresentationInterfaceState.chatLocation {
            case let .replyThread(replyThreadMessage):
                needThreadIdFilter = true
                searchThreadId = replyThreadMessage.threadId
            default:
                needThreadIdFilter = false
                searchThreadId = nil
            }
            transaction.withAllMessages(peerId: message.id.peerId, reversed: true, { searchMessage in
                if result.count >= limit {
                    return false
                }
                if searchMessage.author?.id == authorId {
                    if needThreadIdFilter && searchMessage.threadId != searchThreadId {
                        return true
                    }
                    if searchMessage.media.contains(where: { $0 is TelegramMediaAction }) {
                        return true
                    }
                    result.append(searchMessage.id)
                }
                return true
            })
            return result
        }
        |> deliverOnMainQueue)
        .start(next: { ids in
            interfaceInteraction.beginMessageSelection(ids, { transition in
                f(.custom(transition))
            })
            Queue.mainQueue().async {
                progressDisposable.dispose()
            }
        }, completed: {
            Queue.mainQueue().async {
                progressDisposable.dispose()
            }
        })
    }))
}

func sgInsertContextMenu(actions: inout [ContextMenuItem], sgActions: inout [ContextMenuItem], index: Int?, chatPresentationInterfaceState: ChatPresentationInterfaceState) {
    guard !sgActions.isEmpty else {
        return
    }
    if !actions.isEmpty {
        if let index {
            actions.insert(.separator, at: index)
        } else {
            actions.append(.separator)
        }
    }
    var popSGItems: (() -> Void)? = nil
    sgActions.insert(.action(ContextMenuActionItem(text: chatPresentationInterfaceState.strings.Common_Back, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.actionSheet.primaryTextColor)
    }, iconPosition: .left, action: { _, _ in
        popSGItems?()
    })), at: 0)
    sgActions.insert(.separator, at: 1)
    let sgItems = sgActions
    let swiftgramSubMenu: ContextMenuItem = .action(ContextMenuActionItem(text: "Swiftgram", icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "SwiftgramContextMenu"), color: theme.actionSheet.primaryTextColor)
    }, action: { c, _ in
        popSGItems = { [weak c] in
            c?.popItems()
        }
        c?.pushItems(items: .single(ContextController.Items(content: .list(sgItems))))
    }))
    if let index {
        actions.insert(swiftgramSubMenu, at: index + 1)
    } else {
        actions.append(swiftgramSubMenu)
    }
}
