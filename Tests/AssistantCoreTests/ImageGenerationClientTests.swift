import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AssistantCore

private final class ImageProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ImageGenerationClientTests: XCTestCase {
    func testRequestAndResponse() async throws {
        ImageProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let payload: Data
            if let data = request.httpBody { payload = data }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                payload = data
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "gpt-image-2")
            XCTAssertEqual(body["prompt"] as? String, "кот")
            return (200, Data(#"{"data":[{"b64_json":"aGVsbG8="}]}"#.utf8))
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ImageProtocol.self]
        let client = ImageGenerationClient(session: URLSession(configuration: sessionConfig))
        var config = AssistantConfiguration(model: "chat")
        config.imageModel = "gpt-image-2"
        let image = try await client.generate(prompt: "кот", configuration: config, apiKey: "test-key")
        XCTAssertEqual(image, Data("hello".utf8))
    }
    func testCancelledRequestSurfacesCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageProtocol.self]
        let client = ImageGenerationClient(session: URLSession(configuration: configuration))
        ImageProtocol.handler = { _ in throw URLError(.cancelled) }
        let task = Task { try await client.generate(prompt: "кот", configuration: AssistantConfiguration(model: "chat"), apiKey: "test-key") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }
    func testRejectsOtherOriginsAndHTTPError() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ImageProtocol.self]
        let client = ImageGenerationClient(session: URLSession(configuration: sessionConfig))
        var config = AssistantConfiguration(endpoint: "https://other.example/v1", model: "chat")
        do { _ = try await client.generate(prompt: "кот", configuration: config, apiKey: "test-key"); XCTFail() }
        catch ImageGenerationError.unavailable {}
        config.endpoint = "https://api.openai.com/v1"
        ImageProtocol.handler = { _ in (429, Data()) }
        do { _ = try await client.generate(prompt: "кот", configuration: config, apiKey: "test-key"); XCTFail() }
        catch AssistantClientError.httpStatus(429) {}
    }
}
