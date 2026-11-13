import Foundation
import XCTest
@testable import AssistantCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class AttachmentProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
            }
            let data = try Self.handler(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AttachmentWireTests: XCTestCase, @unchecked Sendable {
    private let image = AssistantAttachment(name: "photo.png", mimeType: "image/png", data: Data([137,80,78,71,13,10,26,10,1]))
    private let file = AssistantAttachment(name: "note.txt", mimeType: "text/plain", data: Data("содержимое".utf8))

    func testLegacyMessageAndImageOnlyContext() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","role":"user","text":"","sources":[]}"#
        let old = try JSONDecoder().decode(AssistantMessage.self, from: Data(json.utf8))
        XCTAssertTrue(old.attachments.isEmpty)
        let user = AssistantMessage(role: .user, text: "", attachments: [image])
        XCTAssertTrue(user.hasContent)
        XCTAssertEqual(AssistantContext.recent([user]), [user])
    }

    func testHTTPAttachmentShapesAndImageOnly() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AttachmentProtocol.self]
        let client = AssistantClient(session: URLSession(configuration: sessionConfig))
        for style in [AssistantAPIStyle.responses, .chatCompletions] {
            AttachmentProtocol.handler = { _, data in
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let messages = try XCTUnwrap(root[style == .responses ? "input" : "messages"] as? [[String: Any]])
                let user = try XCTUnwrap(messages.last)
                let content = try XCTUnwrap(user["content"] as? [[String: Any]])
                XCTAssertEqual(content.count, 2)
                XCTAssertEqual(content[0]["type"] as? String, style == .responses ? "input_image" : "image_url")
                let url = style == .responses ? content[0]["image_url"] as? String : (content[0]["image_url"] as? [String: String])?["url"]
                XCTAssertTrue(url?.hasPrefix("data:image/png;base64,") == true)
                XCTAssertEqual(content[1]["type"] as? String, style == .responses ? "input_text" : "text")
                XCTAssertTrue((content[1]["text"] as? String)?.contains("note.txt") == true)
                XCTAssertTrue((content[1]["text"] as? String)?.contains("содержимое") == true)
                return Data((style == .responses ? #"{"status":"completed","output_text":"OK","output":[]}"# : #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#).utf8)
            }
            let config = AssistantConfiguration(model: "chat", apiStyle: style)
            let reply = try await client.reply(configuration: config, apiKey: "test", messages: [AssistantMessage(role: .user, text: "", attachments: [image, file])])
            XCTAssertEqual(reply.text, "OK")
        }
    }

    func testRealtimeWireAndValidation() throws {
        let message = AssistantMessage(role: .user, text: "", attachments: [image, file])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: RealtimeWire.message(message)) as? [String: Any])
        let item = try XCTUnwrap(payload["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_image", "input_text"])
        XCTAssertTrue((content[0]["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertTrue((content[1]["text"] as? String)?.contains("содержимое") == true)
        XCTAssertThrowsError(try AssistantAttachmentWire.validate([message], supportsImages: false)) { XCTAssertEqual($0 as? AssistantAttachmentError, .unsupportedImages) }
        let bad = AssistantAttachment(name: "bad.png", mimeType: "image/png", data: Data("fake".utf8))
        XCTAssertThrowsError(try AssistantAttachmentWire.validate([AssistantMessage(role: .user, text: "", attachments: [bad])], supportsImages: true))
        XCTAssertThrowsError(try AssistantAttachmentWire.validate([AssistantMessage(role: .user, text: "", attachments: Array(repeating: image, count: 4))], supportsImages: true))
        let long = AssistantAttachment(name: "x.txt", mimeType: "text/plain", data: Data(String(repeating: "a", count: 20_001).utf8))
        XCTAssertThrowsError(try AssistantAttachmentWire.validate([AssistantMessage(role: .user, text: "", attachments: [long])], supportsImages: true))
    }
    func testAggregateTextLimitAcrossMessages() throws {
        let text = AssistantAttachment(name: "part.txt", mimeType: "text/plain", data: Data(String(repeating: "а", count: 20_000).utf8))
        let messages = (0..<3).map { _ in AssistantMessage(role: .user, text: "", attachments: [text]) }
        XCTAssertNoThrow(try AssistantAttachmentWire.validate(messages, supportsImages: true))
        let extra = AssistantAttachment(name: "extra.txt", mimeType: "text/plain", data: Data("а".utf8))
        XCTAssertThrowsError(try AssistantAttachmentWire.validate(messages + [AssistantMessage(role: .user, text: "", attachments: [extra])], supportsImages: true)) {
            XCTAssertEqual($0 as? AssistantAttachmentError, .tooLarge)
        }
    }
    func testRealtimeCanEncodeThreeMaximumSizeImages() throws {
        var data = Data([137,80,78,71,13,10,26,10])
        data.append(Data(repeating: 255, count: 2 * 1024 * 1024 - data.count))
        let image = AssistantAttachment(name: "large.png", mimeType: "image/png", data: data)
        let message = AssistantMessage(role: .user, text: "", attachments: [image, image, image])
        let encoded = try RealtimeWire.message(message)
        XCTAssertLessThan(encoded.count, RealtimeWire.maximumOutgoingEventBytes)
        XCTAssertGreaterThan(encoded.count, RealtimeWire.maximumEventBytes)
    }
    func testContextSelectionExcludesOldAttachmentFromValidation() throws {
        let oversized = AssistantAttachment(name: "too-large.png", mimeType: "image/png", data: Data(repeating: 1, count: 2 * 1024 * 1024 + 1))
        let old = AssistantMessage(role: .user, text: "old", attachments: [oversized])
        let current = (0..<5).map { AssistantMessage(role: .user, text: "message \($0)") }
        let selected = AssistantContext.recent([old] + current, limit: 5)
        XCTAssertEqual(selected, current)
        XCTAssertNoThrow(try AssistantAttachmentWire.validate(selected, supportsImages: true))
        XCTAssertThrowsError(try AssistantAttachmentWire.validate([old] + selected, supportsImages: true))
    }
    func testCustomProviderVisionOptInPersists() throws {
        var provider = AssistantProvider(name: "Other", endpoint: "https://other.test/v1")
        XCTAssertFalse(provider.configuration(for: "chat").supportsImageInput)
        provider.imageInputEnabled = true
        let decoded = try JSONDecoder().decode(AssistantProvider.self, from: JSONEncoder().encode(provider))
        XCTAssertTrue(decoded.configuration(for: "chat").supportsImageInput)
        XCTAssertTrue(AssistantConfiguration(model: "chat").supportsImageInput)
    }
}
