import Foundation
import SwiftUI
import UIKit
import SGSwiftUI
import SGSimpleSettings
import AccountContext
import Display
import TelegramCore
import TelegramPresentationData

private func sgFilterText(_ lang: String, _ ru: String, _ en: String) -> String {
    return (lang == "ru" || lang == "uk" || lang == "be") ? ru : en
}

private final class SGFilterPatternsEditing: NSObject, ObservableObject {
    @Published var editMode: EditMode = .inactive
    weak var controller: ViewController?
    var strings: PresentationStrings = defaultPresentationStrings

    func updateBarButton() {
        controller?.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: editMode.isEditing ? strings.Common_Done : strings.Common_Edit,
            style: editMode.isEditing ? .done : .plain,
            target: self,
            action: #selector(toggleEditing)
        )
    }

    @objc private func toggleEditing() {
        withAnimation {
            editMode = editMode.isEditing ? .inactive : .active
        }
        updateBarButton()
    }
}

private struct SGFilterPatternsView: View {
    @Environment(\.lang) var lang: String
    @ObservedObject var editing: SGFilterPatternsEditing
    let context: AccountContext

    @State private var newPattern: String = ""
    @State private var errorText: String?
    @State private var patterns: [String] {
        didSet {
            SGSimpleSettings.shared.filterPatterns = patterns
        }
    }

    init(editing: SGFilterPatternsEditing, context: AccountContext) {
        self.editing = editing
        self.context = context
        _patterns = State(initialValue: SGSimpleSettings.shared.filterPatterns)
    }

    var bodyContent: some View {
        List {
            Section(footer: Text(sgFilterText(lang, "Сообщение скрывается, если его текст совпадает хотя бы с одним шаблоном. Шаблон — регулярное выражение без учёта регистра, например: казино|ставки или ^\\+\\d+$. Ваши сообщения не скрываются.", "A message is hidden when its text matches any pattern. Patterns are case-insensitive regular expressions, for example: casino|bets or ^\\+\\d+$. Your own messages are never hidden."))) {
                HStack {
                    TextField(sgFilterText(lang, "Новый шаблон", "New pattern"), text: $newPattern)
                        .autocorrectionDisabled(true)
                        .autocapitalization(.none)
                        .onSubmit {
                            addPattern()
                        }
                    Button(action: addPattern) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                            .imageScale(.large)
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(PlainButtonStyle())
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            Section(header: Text(sgFilterText(lang, "ШАБЛОНЫ", "PATTERNS"))) {
                ForEach(patterns.reversed(), id: \.self) { pattern in
                    Text(pattern)
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { indexSet in
                    let originalIndices = IndexSet(indexSet.map { patterns.count - 1 - $0 })
                    withAnimation {
                        patterns.remove(atOffsets: originalIndices)
                    }
                }
            }
        }
    }

    var body: some View {
        bodyContent
            .environment(\.editMode, $editing.editMode)
            .sgNavigationTitle(sgFilterText(lang, "Шаблоны фильтра", "Filter Patterns"))
            .onAppear(perform: updateBarButton)
    }

    private func updateBarButton() {
        editing.strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        editing.updateBarButton()
    }

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let error = sgValidateFilterPattern(trimmed) {
            errorText = sgFilterText(lang, "Неверное выражение: ", "Invalid expression: ") + error
            return
        }
        errorText = nil
        guard !patterns.contains(trimmed) else {
            newPattern = ""
            return
        }
        withAnimation {
            patterns.append(trimmed)
        }
        newPattern = ""
    }
}

public func sgFilterPatternsController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let editing = SGFilterPatternsEditing()
    let controller = SGSwiftUIController(
        title: sgFilterText(presentationData.strings.baseLanguageCode, "Шаблоны фильтра", "Filter Patterns"),
        presentationData: presentationData,
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        SGFilterPatternsView(editing: editing, context: context)
    }
    editing.controller = controller
    editing.strings = presentationData.strings
    editing.updateBarButton()
    return controller
}
