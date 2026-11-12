// Portable file/privacy checks; no app data or external services.
// swiftc Findy/SessionLog.swift Tests/DeviceAudio/SessionLogSmoke.swift -o /tmp/findy-log-smoke
import Foundation

private enum LogSmokeError: Error { case assertion(String), httpStatus(Int) }

@main
struct SessionLogSmoke {
    static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw LogSmokeError.assertion(message) }
        }
        let secret = "sk-private-secret"
        let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: "\(secret) https://user:password@example.com private transcript"])
        let description = DiagnosticLogPrivacy.describe(error)
        try check(description.contains("domain=NSURLErrorDomain") && description.contains("code=-1001") && !description.contains(secret) && !description.contains("password"), "Error payload escaped")
        try check(DiagnosticLogPrivacy.describe(LogSmokeError.httpStatus(429)).contains("httpStatus=429"), "HTTP status lost")
        let httpMetadata = DiagnosticLogPrivacy.metadata(DiagnosticLogPrivacy.describe(LogSmokeError.httpStatus(429)))
        try check(httpMetadata.contains("httpStatus=429") && !httpMetadata.contains("fourCC="), "HTTP status lost after empty FourCC")
        try check(DiagnosticLogPrivacy.metadata("mode=AVAudioSessionModeVoiceChat sampleRate=48000").contains("sampleRate=48000"), "VPIO route mode hid following metadata")
        let details = DiagnosticLogPrivacy.metadata("code=-1001 sampleRate=24000 requireBluetooth=false source=UI input=BluetoothHFP model=\(secret) name=PrivateAirPods message=\(secret) endpoint=https://user:password@example.com code=123456")
        try check(!details.contains(secret) && !details.contains("Private") && !details.contains("password") && details.contains("sampleRate=24000") && details.contains("input=BluetoothHFP"), "Metadata privacy failed")
        try check(!details.contains("123456"), "Allowed-looking metadata inside private text escaped")
        let old = DiagnosticLogPrivacy.storedLine("2026-11-12T18:00:00Z assistant.request.failed state=active code=401 message=\(secret) code=123456") ?? ""
        try check(!old.contains(secret) && old.contains("assistant.request.failed") && old.contains("code=401"), "Historical export not sanitized")
        try check(!old.contains("123456"), "Historical payload was parsed as structured metadata")
        try check(DiagnosticLogPrivacy.storedLine("private transcript \(secret)") == nil, "Unstructured old content retained")

        let directory = FileManager.default.temporaryDirectory.appending(path: "Findy.LogSmoke.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "diagnostic.log")
        try check(try DiagnosticLogFile.tail(at: url).isEmpty, "Missing-file read")
        let line = "2026-11-12T18:00:00Z event state=active count=123\n"
        try Data(String(repeating: line, count: 30_000).utf8).write(to: url)
        let tail = try DiagnosticLogFile.tail(at: url)
        try check(tail.utf8.count <= DiagnosticLogFile.maximumBytes && tail.hasPrefix("2026-"), "Tail wasn't bounded to complete lines")
        for index in 0..<3_000 { try DiagnosticLogFile.append(Data("\(line.dropLast()) code=\(index)\n".utf8), to: url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        try check((size?.intValue ?? Int.max) <= DiagnosticLogFile.maximumBytes, "Disk log grew beyond limit")
        try check(try DiagnosticLogFile.tail(at: url).contains("code=2999"), "Latest event lost in rotation")
        print("PASS: diagnostic error privacy, legacy sanitization, bounded tail and 3,000 append/rotation checks; temporary files only.")
    }
}
