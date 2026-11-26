import Foundation
import SwiftUI
import UIKit
import SGSwiftUI
import SGSimpleSettings
import AccountContext
import Display

private func sgToolsText(_ lang: String, _ ru: String, _ en: String) -> String {
    return (lang == "ru" || lang == "uk" || lang == "be") ? ru : en
}

// MARK: Text viewer

/// Text shown in a viewer screen; it can arrive after the screen opens.
public final class SGTextViewerModel: ObservableObject {
    @Published public var text: String
    @Published public var isLoading: Bool

    public init(text: String, isLoading: Bool) {
        self.text = text
        self.isLoading = isLoading
    }

    /// Main queue only.
    public func finish(text: String) {
        self.text = text
        self.isLoading = false
    }
}

private struct SGTextViewerView: View {
    @ObservedObject var model: SGTextViewerModel
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.top, 24)
                }
                Text(model.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .sgNavigationTitle(title)
    }
}

public func sgTextViewerController(context: AccountContext, title: String, model: SGTextViewerModel) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let controller = SGSwiftUIController(
        title: title,
        presentationData: presentationData,
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        SGTextViewerView(model: model, title: title)
    }
    return controller
}

// MARK: Lyrics (lrclib.net)

private func sgStripLrcTimestamps(_ synced: String) -> String {
    var lines: [String] = []
    for line in synced.components(separatedBy: "\n") {
        var current = Substring(line)
        while current.hasPrefix("["), let end = current.firstIndex(of: "]") {
            current = current[current.index(after: end)...]
        }
        lines.append(current.trimmingCharacters(in: .whitespaces))
    }
    return lines.joined(separator: "\n")
}

private func sgLyricsText(from item: [String: Any]) -> String? {
    if let plain = item["plainLyrics"] as? String, !plain.isEmpty {
        return plain
    }
    if let synced = item["syncedLyrics"] as? String, !synced.isEmpty {
        return sgStripLrcTimestamps(synced)
    }
    return nil
}

/// Looks the song up on lrclib.net. Calls back on the main queue with the lyrics, or nil when there are none.
public func sgFetchLyrics(title: String, artist: String?, completion: @escaping (String?) -> Void) {
    var components = URLComponents(string: "https://lrclib.net/api/search")!
    var queryItems = [URLQueryItem(name: "track_name", value: title)]
    if let artist, !artist.isEmpty {
        queryItems.append(URLQueryItem(name: "artist_name", value: artist))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
        completion(nil)
        return
    }
    var request = URLRequest(url: url)
    request.setValue("Swiftgram (https://github.com/Swiftgram/Telegram-iOS)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20
    URLSession.shared.dataTask(with: request) { data, _, _ in
        var result: String?
        if let data, let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for item in items {
                if let text = sgLyricsText(from: item) {
                    result = text
                    break
                }
            }
        }
        DispatchQueue.main.async {
            completion(result)
        }
    }.resume()
}

// MARK: AI service (OpenAI-compatible chat completions)

public var sgIsAIServiceConfigured: Bool {
    let settings = SGSimpleSettings.shared
    return !settings.aiEndpoint.trimmingCharacters(in: .whitespaces).isEmpty && !settings.aiApiKey.trimmingCharacters(in: .whitespaces).isEmpty
}

private func sgChatCompletionsURL(_ endpoint: String) -> URL? {
    var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix("/") {
        value.removeLast()
    }
    if !value.hasSuffix("/chat/completions") {
        value += "/chat/completions"
    }
    return URL(string: value)
}

/// Sends the text with an instruction. Calls back on the main queue with the answer or an error description.
public func sgAskAI(instruction: String, text: String, completion: @escaping (Result<String, Error>) -> Void) {
    struct SGAIError: LocalizedError {
        let message: String
        var errorDescription: String? { return self.message }
    }
    let settings = SGSimpleSettings.shared
    guard let url = sgChatCompletionsURL(settings.aiEndpoint) else {
        completion(.failure(SGAIError(message: "Invalid service address")))
        return
    }
    let model = settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty ? "gpt-4o-mini" : settings.aiModel.trimmingCharacters(in: .whitespaces)
    let body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": instruction],
            ["role": "user", "content": text]
        ]
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(settings.aiApiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request) { data, response, error in
        let result: Result<String, Error>
        if let error {
            result = .failure(error)
        } else if let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String {
                result = .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let errorObject = json["error"] as? [String: Any], let message = errorObject["message"] as? String {
                result = .failure(SGAIError(message: message))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .failure(SGAIError(message: "Unexpected response (HTTP \(status))"))
            }
        } else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(SGAIError(message: "Empty response (HTTP \(status))"))
        }
        DispatchQueue.main.async {
            completion(result)
        }
    }.resume()
}

// MARK: AI service settings

private struct SGAIServiceSettingsView: View {
    @Environment(\.lang) var lang: String

    @State private var endpoint: String = SGSimpleSettings.shared.aiEndpoint
    @State private var apiKey: String = SGSimpleSettings.shared.aiApiKey
    @State private var model: String = SGSimpleSettings.shared.aiModel
    @State private var customPrompt: String = SGSimpleSettings.shared.aiCustomPrompt

    var body: some View {
        List {
            Section(header: Text(sgToolsText(lang, "АДРЕС СЕРВИСА", "SERVICE ADDRESS")), footer: Text(sgToolsText(lang, "Любой сервис, совместимый с OpenAI API, например https://api.openai.com/v1 или https://openrouter.ai/api/v1.", "Any OpenAI-compatible service, for example https://api.openai.com/v1 or https://openrouter.ai/api/v1."))) {
                TextField("https://api.openai.com/v1", text: $endpoint)
                    .autocorrectionDisabled(true)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .onChange(of: endpoint) { value in
                        SGSimpleSettings.shared.aiEndpoint = value
                    }
            }
            Section(header: Text(sgToolsText(lang, "КЛЮЧ API", "API KEY")), footer: Text(sgToolsText(lang, "Ключ хранится только на этом устройстве и отправляется только на указанный адрес.", "The key is stored on this device only and is sent only to the address above."))) {
                SecureField("sk-...", text: $apiKey)
                    .autocorrectionDisabled(true)
                    .autocapitalization(.none)
                    .onChange(of: apiKey) { value in
                        SGSimpleSettings.shared.aiApiKey = value
                    }
            }
            Section(header: Text(sgToolsText(lang, "МОДЕЛЬ", "MODEL"))) {
                TextField("gpt-4o-mini", text: $model)
                    .autocorrectionDisabled(true)
                    .autocapitalization(.none)
                    .onChange(of: model) { value in
                        SGSimpleSettings.shared.aiModel = value
                    }
            }
            Section(header: Text(sgToolsText(lang, "СВОЙ ЗАПРОС", "CUSTOM PROMPT")), footer: Text(sgToolsText(lang, "Если заполнено, в меню сообщения появится «ИИ: свой запрос» с этой инструкцией.", "When set, the message menu gets AI: Custom Prompt with this instruction."))) {
                TextField(sgToolsText(lang, "Например: найди ошибки в тексте", "For example: find mistakes in the text"), text: $customPrompt)
                    .onChange(of: customPrompt) { value in
                        SGSimpleSettings.shared.aiCustomPrompt = value
                    }
            }
        }
        .sgNavigationTitle(sgToolsText(lang, "ИИ-сервис", "AI Service"))
    }
}

public func sgAIServiceController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return SGSwiftUIController(
        title: sgToolsText(presentationData.strings.baseLanguageCode, "ИИ-сервис", "AI Service"),
        presentationData: presentationData,
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        SGAIServiceSettingsView()
    }
}

// MARK: Calculator

private struct SGExpressionParser {
    let chars: [Character]
    var index: Int = 0
    var depth: Int = 0

    init(chars: [Character]) {
        self.chars = chars
    }

    func peek() -> Character? {
        return self.index < self.chars.count ? self.chars[self.index] : nil
    }

    mutating func parseNumber() -> Double? {
        let start = self.index
        while let ch = self.peek(), ch.isNumber || ch == "." {
            self.index += 1
        }
        if start == self.index {
            return nil
        }
        return Double(String(self.chars[start ..< self.index]))
    }

    mutating func parsePrimary() -> Double? {
        guard let ch = self.peek() else {
            return nil
        }
        if ch == "-" {
            self.index += 1
            return self.parsePrimary().map { -$0 }
        }
        if ch == "+" {
            self.index += 1
            return self.parsePrimary()
        }
        if ch == "(" {
            self.index += 1
            self.depth += 1
            if self.depth > 50 {
                return nil
            }
            let value = self.parseSum()
            self.depth -= 1
            guard self.peek() == ")" else {
                return nil
            }
            self.index += 1
            return value
        }
        return self.parseNumber()
    }

    mutating func parsePower() -> Double? {
        guard let base = self.parsePrimary() else {
            return nil
        }
        if self.peek() == "^" {
            self.index += 1
            guard let exponent = self.parsePower() else {
                return nil
            }
            return pow(base, exponent)
        }
        return base
    }

    mutating func parseProduct() -> Double? {
        guard var value = self.parsePower() else {
            return nil
        }
        while let ch = self.peek(), ch == "*" || ch == "/" || ch == "%" {
            self.index += 1
            guard let rhs = self.parsePower() else {
                return nil
            }
            if ch == "*" {
                value *= rhs
            } else if ch == "/" {
                value /= rhs
            } else {
                value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    mutating func parseSum() -> Double? {
        guard var value = self.parseProduct() else {
            return nil
        }
        while let ch = self.peek(), ch == "+" || ch == "-" {
            self.index += 1
            guard let rhs = self.parseProduct() else {
                return nil
            }
            value = ch == "+" ? value + rhs : value - rhs
        }
        return value
    }
}

/// Evaluates + - * / % ^ and parentheses with a recursive-descent parser. Returns nil for anything else.
public func sgEvaluateExpression(_ input: String) -> Double? {
    var chars: [Character] = []
    for ch in input {
        switch ch {
        case " ", "\t", "\n", "\r":
            continue
        case "×", "x", "X":
            chars.append("*")
        case "÷", ":":
            chars.append("/")
        case ",":
            chars.append(".")
        case "−", "–":
            chars.append("-")
        default:
            chars.append(ch)
        }
    }
    if chars.isEmpty || chars.count > 500 {
        return nil
    }
    var parser = SGExpressionParser(chars: chars)
    guard let result = parser.parseSum(), parser.index == chars.count, result.isFinite else {
        return nil
    }
    return result
}

/// Whether the text is a calculation worth offering: it has an operator and evaluates.
public func sgIsCalculation(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count < 3 || trimmed.count > 200 {
        return false
    }
    guard trimmed.dropFirst().contains(where: { "+-*/×÷^%".contains($0) }) else {
        return false
    }
    return sgEvaluateExpression(trimmed) != nil
}

public func sgFormatCalculation(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 10
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private struct SGCalculatorView: View {
    @Environment(\.lang) var lang: String
    @State private var expression: String = ""

    var body: some View {
        List {
            Section(footer: Text(sgToolsText(lang, "Поддерживаются + − × ÷ % ^ и скобки.", "Supports + − × ÷ % ^ and parentheses."))) {
                TextField("12 * (3 + 4)", text: $expression)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled(true)
                    .font(.system(.title3, design: .monospaced))
            }
            Section(header: Text(sgToolsText(lang, "РЕЗУЛЬТАТ", "RESULT"))) {
                if let value = sgEvaluateExpression(expression) {
                    Text(sgFormatCalculation(value))
                        .font(.system(.title, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(expression.isEmpty ? "—" : sgToolsText(lang, "Неверное выражение", "Invalid expression"))
                        .foregroundColor(.secondary)
                }
            }
        }
        .sgNavigationTitle(sgToolsText(lang, "Калькулятор", "Calculator"))
    }
}

public func sgCalculatorController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return SGSwiftUIController(
        title: sgToolsText(presentationData.strings.baseLanguageCode, "Калькулятор", "Calculator"),
        presentationData: presentationData,
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        SGCalculatorView()
    }
}
