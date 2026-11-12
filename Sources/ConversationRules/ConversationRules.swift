import Foundation

/// The intentionally small conversation contract, independent of audio and Siri.
public enum ConversationRules {
    public static let silenceTimeout: TimeInterval = 5
    public static let utterancePause: TimeInterval = 0.9

    public static func reply(to transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if trimmed.lowercased(with: Locale(identifier: "ru_RU")) == "привет" {
            return "Привет! Я твой голосовой помощник"
        }
        return "Функция общения пока не реализована"
    }

    /// Keep visible citations in the chat while speaking the actual answer.
    public static func displayText(from text: String) -> String {
        text.replacingOccurrences(of: #"[^]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func spokenText(from text: String, sourceURLs: [URL] = []) -> String {
        var value = displayText(from: text)
        var links: [SpeechLink] = []
        let tokenPrefix = "\u{E100}" + UUID().uuidString
        func linkToken(label: String) -> String {
            let token = tokenPrefix + "\(links.count)\u{E101}"
            links.append(SpeechLink(token: token, label: label))
            return token
        }

        // Keep labels as tokens until citation-only lines and parentheses have
        // been removed. An inline phrase such as "по [данным NASA](url)" keeps
        // its words, while a separate "[NASA](url)" source does not get read.
        value = replacingMatches(
            value,
            pattern: #"(?<!!)\[([^\]\n]+)\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()\s]*\))+)(?:[ \t]+["'][^"'\n]*["'])?\s*\)"#
        ) { groups in
            let destination = groups[2].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return isWebAddress(destination) ? linkToken(label: groups[1]) : groups[0]
        }
        value = replacingMatches(
            value,
            pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#
        ) { groups in
            isWebAddress(groups[1]) ? linkToken(label: groups[2]) : groups[0]
        }
        value = replacingMatches(value, pattern: #"<([^<>\n]+)>"#) { groups in
            isWebAddress(groups[1]) ? linkToken(label: "") : groups[0]
        }
        value = replacingMatches(value, pattern: webAddressPattern) { groups in
            let punctuation = trailingURLPunctuation(groups[0])
            return linkToken(label: "") + punctuation
        }
        let hasCitations = !links.isEmpty || !sourceURLs.isEmpty || text.contains("cite") || text.contains("†")
        value = removingSourceBlocks(value, links: links, hasSourceMetadata: !sourceURLs.isEmpty)
        if hasCitations {
            value = value.replacingOccurrences(of: #"\[\^?\d+(?:[ \t]*[,;–-][ \t]*\d+)*\]"#, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"【\d+(?::\d+)?(?:†[^】]*)?】"#, with: "", options: .regularExpression)

        for _ in 0..<3 {
            value = replacingMatches(value, pattern: #"\(([^()\n]*)\)"#) { groups in
                isCitationOnly(groups[1], links: links) ? "" : groups[0]
            }
        }
        value = value.components(separatedBy: "\n").filter { !isCitationOnly($0, links: links) }.joined(separator: "\n")
        if !links.isEmpty {
            let token = "(?:" + links.map { NSRegularExpression.escapedPattern(for: $0.token) }.joined(separator: "|") + ")"
            value = value.replacingOccurrences(
                of: #"(?<=[.!?…])[ \t]*"# + token + "(?:[ \t,;]+" + token + #")*[ \t]*[.,;!?]?[ \t]*(?=$|\n)"#,
                with: "",
                options: .regularExpression
            )
        }
        for link in links.reversed() {
            let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let citationLabel = label.range(of: #"(?i)^(?:\^?\d+(?:\s*[,;–-]\s*\d+)*|источник|ссылка|source|reference)$"#, options: .regularExpression) != nil
            value = value.replacingOccurrences(of: link.token, with: citationLabel || isWebAddress(label) ? "" : label)
        }
        value = value.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*[-*•>][ \t]+"#, with: "", options: .regularExpression)
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            value = String(attributed.characters)
        }
        value = value.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])(?:[ \t]*\1)+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([.!?])(?:[ \t]+[.!?])+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.rangeOfCharacter(from: .alphanumerics) == nil ? "Ответ доступен в приложении." : value
    }

    private struct SpeechLink {
        let token: String
        let label: String
    }

    // Deliberately avoid arbitrary "word.extension" matches: common source
    // domains are recognized, while Node.js, app.swift, decimals and versions
    // remain ordinary speech. Explicit http(s) and www addresses accept any TLD.
    private static let webAddressPattern: String = {
        let labels = #"(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+"#
        let suffix = #"(?::\d+)?(?:[/?#][^\s<>"“”'«»\[\]{}]*)?"#
        let tlds = "com|org|net|edu|gov|mil|int|io|ai|ru|рф|su|uk|de|fr|es|eu|us|cn|jp|info|news|tech|app|dev|me|biz|online|site|xyz|cloud|co|tv|pro|mobi|store|name|ua|by|kz|ca|au|ch|it|nl|br|in|live|today|world|museum|xn--p1ai"
        return #"(?i)(?<![\p{L}\p{N}_@.\-])(?:https?://[^\s<>"“”'«»\[\]{}]+|www\."#
            + labels + #"[\p{L}]{2,63}"# + suffix + "|"
            + labels + "(?:" + tlds + #")(?![\p{L}\p{N}_-]|\.[\p{L}\p{N}])"# + suffix + ")"
    }()

    private static func isWebAddress(_ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: webAddressPattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return false }
        return match.range == NSRange(value.startIndex..., in: value)
    }

    private static func trailingURLPunctuation(_ candidate: String) -> String {
        var address = candidate
        var punctuation = ""
        while let last = address.last {
            let sentencePunctuation = ".,;:!?".contains(last)
            let unbalancedClose = last == ")" && address.filter { $0 == ")" }.count > address.filter { $0 == "(" }.count
            guard sentencePunctuation || unbalancedClose else { break }
            punctuation.insert(address.removeLast(), at: punctuation.startIndex)
        }
        return punctuation
    }

    private static func isCitationOnly(_ text: String, links: [SpeechLink]) -> Bool {
        guard links.contains(where: { text.contains($0.token) }) else { return false }
        var remaining = text
        for link in links { remaining = remaining.replacingOccurrences(of: link.token, with: "") }
        remaining = remaining.replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:источники?|ссылки?|sources?|references?|см|see|подробнее|подробности|via|по данным|и|and)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        return remaining.isEmpty
    }

    private static func removingSourceBlocks(_ text: String, links: [SpeechLink], hasSourceMetadata: Bool) -> String {
        var output: [String] = []
        var insideSources = false
        var blankAfterSource = false
        for line in text.components(separatedBy: "\n") {
            let plain = line.replacingOccurrences(of: #"[*_\x{0060}#]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceHeading = plain.range(of: #"(?i)^(?:источники|ссылки|sources|references)\s*:?\s*$"#, options: .regularExpression) != nil
            let inlineSourceHeading = plain.range(of: #"(?i)^(?:источники|ссылки|sources|references)\s*:"#, options: .regularExpression) != nil
                && (hasSourceMetadata || links.contains { plain.contains($0.token) })
            if sourceHeading || inlineSourceHeading {
                insideSources = true
                blankAfterSource = false
                continue
            }
            let sourceDefinition = plain.range(of: #"^\[\^?[^\]]+\]:"#, options: .regularExpression) != nil
                && links.contains { plain.contains($0.token) }
            if sourceDefinition { continue }
            if insideSources {
                if plain.isEmpty {
                    blankAfterSource = true
                    continue
                }
                let listEntry = plain.range(of: #"^\s*(?:[-•]|\d+[.)])\s+"#, options: .regularExpression) != nil
                let nextHeading = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) != nil
                if nextHeading || (blankAfterSource && !listEntry && !links.contains { line.contains($0.token) }) {
                    insideSources = false
                } else {
                    continue
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func replacingMatches(_ value: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let original = value as NSString
        var result = value
        for match in expression.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index in
                match.range(at: index).location == NSNotFound ? "" : original.substring(with: match.range(at: index))
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: transform(groups))
        }
        return result
    }
}

/// A monotonic listening clock. The caller supplies system uptime and resets it
/// after speech synthesis, so the assistant's own response never counts as silence.
public struct SilenceClock {
    private let timeout: TimeInterval
    private var lastActivity: TimeInterval
    private var hasSpeech = false

    public init(now: TimeInterval, timeout: TimeInterval = ConversationRules.silenceTimeout) {
        self.timeout = timeout.isFinite && timeout >= 0 ? timeout : ConversationRules.silenceTimeout
        lastActivity = now
    }

    public mutating func heardSpeech(at now: TimeInterval) {
        guard now >= lastActivity else { return }
        lastActivity = now
        hasSpeech = true
    }

    public mutating func resumedListening(at now: TimeInterval) {
        guard now >= lastActivity else { return }
        lastActivity = now
        hasSpeech = false
    }

    public func shouldEndSession(at now: TimeInterval) -> Bool {
        timeout > 0 && now >= lastActivity + timeout
    }

    public func shouldFinishUtterance(at now: TimeInterval) -> Bool {
        hasSpeech && now >= lastActivity + ConversationRules.utterancePause
    }
}
