import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Images API. The response bytes are returned to the caller for local storage,
/// and are never placed in conversation context.
public struct ImageGenerationClient: Sendable {
    private let injectedSession: URLSession?
    public init(session: URLSession? = nil) { self.injectedSession = session }
    public func generate(prompt: String, configuration: AssistantConfiguration, apiKey: String) async throws -> Data {
        guard configuration.supportsImageGeneration else { throw ImageGenerationError.unavailable }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 32_000 else { throw ImageGenerationError.invalidPrompt }
        guard !apiKey.isEmpty, apiKey.rangeOfCharacter(from: .newlines) == nil else { throw AssistantClientError.invalidAPIKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": configuration.imageModel, "prompt": prompt, "n": 1, "output_format": "png"])
        let session = injectedSession ?? URLSession(configuration: .ephemeral, delegate: ImageRedirectGuard(), delegateQueue: nil)
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AssistantClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AssistantClientError.httpStatus(http.statusCode) }
        guard let encoded = try JSONDecoder().decode(Response.self, from: data).data.first?.b64_json,
              let image = Data(base64Encoded: encoded), !image.isEmpty, image.count <= 50_000_000 else { throw ImageGenerationError.invalidImage }
        return image
    }
    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String? }
        let data: [Item]
    }
}
public enum ImageGenerationError: Error, LocalizedError {
    case unavailable, invalidPrompt, invalidImage
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Создание изображений доступно только через OpenAI."
        case .invalidPrompt: "Не удалось сформировать описание изображения."
        case .invalidImage: "Сервис вернул повреждённое изображение."
        }
    }
}
private final class ImageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
