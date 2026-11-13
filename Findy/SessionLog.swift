import Foundation
#if canImport(UIKit)
import OSLog
import UIKit

@MainActor
final class SessionLog: ObservableObject {
    static let shared = SessionLog()

    @Published private(set) var lines: [String] = []
    @Published private(set) var writeError: String?
    @Published private(set) var isExportSafe = false
    let fileURL: URL
    let processID = UUID().uuidString

    private let logger = Logger(subsystem: "com.khodyrev.findy", category: "VoiceSession")
    private let formatter = ISO8601DateFormatter()

    private init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Diagnostics")
        fileURL = directory.appending(path: "voice-session.log")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            lines = Array(try prepareLog().suffix(200))
            isExportSafe = true
        } catch {
            writeError = error.localizedDescription
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        record("process.started", "process=\(processID) build=\(build) iOS=\(UIDevice.current.systemVersion)")
    }

    func record(_ event: String, _ details: String = "") {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let metadata = DiagnosticLogPrivacy.metadata(details)
        let line = "\(formatter.string(from: Date())) \(DiagnosticLogPrivacy.event(event)) state=\(state) protectedData=\(UIApplication.shared.isProtectedDataAvailable) \(metadata)"
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        logger.info("\(line, privacy: .public)")

        do {
            if !isExportSafe {
                _ = try prepareLog()
                isExportSafe = true
            }
            let data = Data((line + "\n").utf8)
            try DiagnosticLogFile.append(data, to: fileURL)
            try protectFile()
            writeError = nil
        } catch {
            writeError = error.localizedDescription
            logger.error("Cannot write diagnostic log: \(Self.describe(error), privacy: .public)")
        }
    }

    static func describe(_ error: Error) -> String {
        DiagnosticLogPrivacy.describe(error)
    }

    private func protectFile() throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
    }

    private func prepareLog() throws -> [String] {
        let previous = try DiagnosticLogFile.tail(at: fileURL)
        let sanitized = previous.split(separator: "\n").compactMap { DiagnosticLogPrivacy.storedLine(String($0)) }
        // Upgrade existing logs as well: exports must not retain older raw
        // provider error messages or user-assigned audio device names.
        try Data((sanitized.joined(separator: "\n") + (sanitized.isEmpty ? "" : "\n")).utf8).write(to: fileURL, options: .atomic)
        try protectFile()
        return sanitized
    }
}
#endif

/// Diagnostic exports contain operational metadata only. Free-form provider,
/// recognizer and URL error descriptions are deliberately never serialized.
enum DiagnosticLogPrivacy {
    private static let numericKeys: Set<String> = ["build", "iOS", "attempt", "sampleRate", "options", "routePolicy", "levelDB", "characters", "sources", "contextMessages", "updates", "chunks", "pcmBytes", "transcriptCharacters", "bytes", "heardMS", "removed", "retainedMessages", "inputTokens", "outputTokens", "audioIn", "audioOut", "cached", "quality", "rate", "pcm", "type", "code", "httpStatus", "microphone", "speech", "count"]
    private static let booleanKeys: Set<String> = ["protectedData", "requireBluetooth", "allowBluetoothHFP", "mixWithOthers", "otherAudio", "onDevice", "requiresOnDeviceRecognition", "searchEnabled", "webSearch", "tool"]
    private static let enumValues: [String: Set<String>] = [
        "state": ["active", "inactive", "background", "unknown"], "phase": ["active", "inactive", "background"],
        "source": ["UI", "AppIntent"], "intent": ["StartChatIntent"], "engine": ["realtime"],
        "api": ["responses", "chatCompletions", "realtime"], "tool": ["web_search", "manage_memory", "manage_reminders", "get_current_context", "generate_image", "unknown"], "name": ["web_search", "manage_memory", "manage_reminders", "get_current_context", "generate_image", "unknown"],
        "action": ["create", "update", "complete", "delete"], "status": ["completed", "failed", "cancelled", "incomplete"],
        "value": ["active", "dismissed", "ended", "stale"],
        "input": ["BluetoothHFP", "MicrophoneBuiltIn", "HeadsetMic", "USBAudio"],
        "output": ["BluetoothHFP", "BluetoothA2DPOutput", "Speaker", "Receiver", "Headphones", "USBAudio"],
        "category": ["AVAudioSessionCategoryPlayAndRecord", "playAndRecord"], "mode": ["AVAudioSessionModeDefault", "AVAudioSessionModeVoiceChat", "default", "voiceChat"],
        "microphone": ["granted", "denied", "undetermined"], "speech": ["authorized", "denied", "restricted", "notDetermined"], "onDevice": ["true", "false"]
    ]

    static func event(_ value: String) -> String {
        matches(value, #"^[A-Za-z][A-Za-z0-9_.]{0,79}$"#) ? value : "diagnostic.event"
    }

    static func metadata(_ value: String) -> String {
        var result: [String] = []
        for token in value.split(whereSeparator: \.isWhitespace).prefix(48) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { break }
            let key = String(pair[0]), content = String(pair[1])
            if key == "fourCC", content.isEmpty { continue }
            let allowed: Bool
            if key == "iOS" { allowed = matches(content, #"^[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}$"#) }
            else if numericKeys.contains(key) { allowed = matches(content, #"^-?[0-9]{1,12}(?:\.[0-9]{1,8})?$"#) }
            else if booleanKeys.contains(key), content == "true" || content == "false" { allowed = true }
            else if ["id", "process", "turn"].contains(key) { allowed = UUID(uuidString: content) != nil }
            else if key == "domain" { allowed = safeDomain(content) == content }
            else if key == "fourCC" { allowed = matches(content, #"^[A-Za-z0-9!?_-]{1,4}$"#) }
            else if key == "input" || key == "output" {
                let values = content.split(separator: ",", omittingEmptySubsequences: false)
                allowed = !values.isEmpty && values.count <= 8 && values.allSatisfy { enumValues[key]?.contains(String($0)) == true }
            } else { allowed = enumValues[key]?.contains(content) == true }
            // An untrusted free-text value can itself contain `code=...` or
            // another allowed-looking token. Keep only the structured prefix;
            // never resume parsing inside error payloads or device/model names.
            guard allowed else { break }
            result.append(key + "=" + content)
        }
        return result.joined(separator: " ")
    }

    static func storedLine(_ line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count >= 2, matches(fields[0], #"^[0-9]{4}-[0-9T:Z.+-]{15,35}$"#), event(fields[1]) == fields[1] else { return nil }
        return fields[0] + " " + fields[1] + " " + metadata(fields.count == 3 ? fields[2] : "")
    }

    static func describe(_ error: Error) -> String {
        let value = error as NSError
        let number = UInt32(truncatingIfNeeded: value.code)
        let bytes = [24, 16, 8, 0].map { UInt8((number >> $0) & 0xff) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii) ?? ""
            : ""
        var result = "domain=\(safeDomain(value.domain)) code=\(value.code)"
        if !fourCC.isEmpty { result += " fourCC=\(fourCC)" }
        // Preserve useful HTTP status without inspecting any server payload.
        if let child = Mirror(reflecting: error).children.first, child.label == "httpStatus", let status = child.value as? Int {
            result += " httpStatus=\(status)"
        }
        return result
    }

    private static func safeDomain(_ value: String) -> String {
        let known: Set<String> = ["NSCocoaErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain", "NSPOSIXErrorDomain", "AVFoundationErrorDomain", "kAFAssistantErrorDomain", "kLSRErrorDomain", "unknown"]
        if known.contains(value) { return value }
        if matches(value, #"^(?:Findy|AssistantCore|LocalData|ProviderSettings|com\.apple)\.[A-Za-z0-9_.]{1,96}$"#) { return value }
        return "unknown"
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

enum DiagnosticLogFile {
    static let maximumBytes = 262_144

    static func tail(at url: URL, limit: Int = maximumBytes) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let offset = length > UInt64(limit) ? length - UInt64(limit) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: limit) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard offset > 0 else { return text }
        return text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
    }

    static func append(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes / 2 else { throw CocoaError(.fileWriteUnknown) }
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let length = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if length + data.count > maximumBytes {
            let previous = try tail(at: url, limit: maximumBytes / 2)
            // Compact well below the limit, so normal appends do not repeatedly
            // rewrite the file. Retain recent history; no unbounded backup file.
            let lines = previous.split(separator: "\n").suffix(200).joined(separator: "\n")
            try Data((lines + (lines.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
