import Foundation
import UIKit


/// Images are stored separately from transcript and model context. Only a local
/// file name, never image bytes, is associated with the transcript message.
@MainActor
enum GeneratedImages {
    static let tool = AssistantToolDefinition(
        name: "generate_image",
        description: "Создай новое изображение по просьбе пользователя. Вызывай только когда пользователь просит нарисовать или сгенерировать изображение; уточни недостающие важные детали. Не утверждай, что изображение готово до успешного результата инструмента.",
        parameters: .init(properties: ["prompt": .init("Подробное описание изображения с учётом запроса и контекста.", maxLength: 32000)], required: ["prompt"])
    )

    private struct Arguments: Decodable { let prompt: String }
    private static func directory(for store: LocalDataStore) -> URL {
        store.databaseURL.deletingLastPathComponent().appendingPathComponent("GeneratedImages", isDirectory: true)
    }
    private static func key(_ id: UUID) -> String { "image." + id.uuidString.lowercased() }
    static func url(for id: UUID) -> URL? {
        guard let store = try? PersonalData.shared.requireStore(),
              let data = try? store.localState(for: key(id)),
              let name = String(data: data, encoding: .utf8), name == id.uuidString.lowercased() + ".png" else { return nil }
        return directory(for: store).appendingPathComponent(name)
    }
    static func removeAllFiles(store: LocalDataStore) throws {
        let folder = directory(for: store)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    static func generate(call: AssistantToolCall, configuration: AssistantConfiguration, apiKey: String, scope: String) async throws -> AssistantToolResult {
        guard call.arguments.utf8.count <= 131_072,
              let data = call.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Arguments.self, from: data) else { throw ImageGenerationError.invalidPrompt }
        let imageData = try await ImageGenerationClient().generate(prompt: args.prompt, configuration: configuration, apiKey: apiKey)
        guard UIImage(data: imageData) != nil else { throw ImageGenerationError.invalidImage }
        try Task.checkCancellation()
        try save(imageData, scope: scope)
        return AssistantToolResult(output: "{\"ok\":true,\"message\":\"Изображение создано и показано пользователю.\"}")
    }
    static func save(_ imageData: Data, scope: String) throws {
        let message = AssistantMessage(role: .assistant, text: "Изображение готово.")
        let name = message.id.uuidString.lowercased() + ".png"
        let store = try PersonalData.shared.requireStore()
        let folder = directory(for: store)
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try imageData.write(to: file, options: .atomic)
        do {
            try store.setLocalState(Data(name.utf8), for: key(message.id))
            do { _ = try ChatTimeline.shared.accept(message, scope: scope) }
            catch { try? store.setLocalState(nil, for: key(message.id)); throw error }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
    #if DEBUG && targetEnvironment(simulator)
    static func saveFixture(scope: String) throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            let text = "Findy · тест изображения" as NSString
            text.draw(at: CGPoint(x: 60, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: UIColor.white])
        }
        guard let data = image.pngData() else { throw ImageGenerationError.invalidImage }
        try save(data, scope: scope)
    }
    #endif
}
