import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct AttachmentPickerButton: View {
    let imagesAllowed: Bool
    let remaining: Int
    let disabled: Bool
    let onImport: (AssistantAttachment) -> Void
    let onError: (String) -> Void
    let onLoading: (Bool) -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingFiles = false
    @State private var importing = false

    var body: some View {
        Menu {
            Button("Фото", systemImage: "photo") { showingPhotos = true }
                .disabled(!imagesAllowed)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Камера", systemImage: "camera") { showingCamera = true }
                    .disabled(!imagesAllowed)
            }
            Button("Файл", systemImage: "doc") { showingFiles = true }
            if !imagesAllowed { Text("Для фото включите поддержку изображений у провайдера.") }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-attachments-fixture"),
               let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"], UUID(uuidString: value) != nil {
                Button("Тестовое фото") { importPhoto(AttachmentUIFixture.photo(), name: "Тестовое фото.jpg") }
                    .disabled(!imagesAllowed)
                Button("Тестовый файл") { onImport(AssistantAttachment(name: "Пример.txt", mimeType: "text/plain", data: Data("Файл для проверки вложений.".utf8))) }
            }
            #endif
        } label: {
            Group {
                if importing { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus").font(.system(size: 20, weight: .medium)) }
            }
            .foregroundStyle(.primary)
            .frame(width: 44, height: 48)
            .contentShape(Circle())
        }
        .onChange(of: importing) { _, value in onLoading(value) }
        .disabled(disabled || remaining <= 0 || importing)
        .findyComposerGlass(in: Circle(), interactive: true)
        .accessibilityLabel("Прикрепить фото или файл")
        .accessibilityIdentifier("chat-attach")
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: max(1, remaining), matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                defer { importing = false; photos = [] }
                for (index, item) in items.enumerated() {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentUIError.unavailable }
                        let attachment = try await Task.detached { try ChatAttachments.importImage(data: data, name: "Фото \(index + 1).jpg") }.value
                        onImport(attachment)
                    } catch { onError(error.localizedDescription) }
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            AttachmentCamera { data in
                showingCamera = false
                if let data { importPhoto(data, name: "Снимок.jpg") }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard urls.count <= remaining else { onError("Можно прикрепить не больше трёх файлов или фото."); return }
                importing = true
                Task {
                    defer { importing = false }
                    for url in urls {
                        do {
                            let attachment = try await Task.detached { try ChatAttachments.importFile(url: url) }.value
                            onImport(attachment)
                        } catch { onError(error.localizedDescription) }
                    }
                }
            case .failure(let error): onError(error.localizedDescription)
            }
        }
    }

    private func importPhoto(_ data: Data, name: String) {
        importing = true
        Task {
            defer { importing = false }
            do { onImport(try await Task.detached { try ChatAttachments.importImage(data: data, name: name) }.value) }
            catch { onError(error.localizedDescription) }
        }
    }
}

@MainActor
struct DraftAttachmentsView: View {
    let attachments: [AssistantAttachment]
    let disabled: Bool
    let onRemove: (UUID) -> Void
    @State private var preview: AttachmentPreviewItem?
    @State private var previewCopy: URL?
    @State private var previewError: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        Button {
                            do {
                                let item = try AttachmentPreviewItem(attachment: attachment)
                                previewCopy = item.url; preview = item
                            } catch { previewError = error.localizedDescription }
                        } label: {
                            AttachmentChip(name: attachment.name, image: attachment.mimeType.hasPrefix("image/") ? AttachmentThumbnail.image(data: attachment.data, maximumPixels: 96) : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Просмотреть \(attachment.name)")
                        Button { onRemove(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityLabel("Убрать \(attachment.name)")
                        .accessibilityIdentifier("attachment-remove")
                    }
                    .padding(.leading, 6)
                    .findyComposerGlass(in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("attachment-draft")
                }
            }
        }
        .fullScreenCover(item: $preview, onDismiss: {
            AttachmentPreviewItem.removeOwnedCopy(previewCopy)
            previewCopy = nil
        }) { AttachmentPreview(item: $0) }
        .alert("Не удалось открыть вложение", isPresented: Binding(get: { previewError != nil }, set: { if !$0 { previewError = nil } })) {
            Button("Понятно", role: .cancel) { previewError = nil }
        } message: { Text(previewError ?? "") }
    }
}

@MainActor
struct MessageAttachmentsView: View {
    let messageID: UUID
    @ObservedObject private var media = MediaStorage.shared
    @State private var preview: AttachmentPreviewItem?
    @State private var previewCopy: URL?
    @State private var previewError: String?
    var body: some View {
        let _ = media.revision
        ForEach(ChatAttachments.list(for: messageID)) { attachment in
            if attachment.isRemoved {
                Label("Вложение удалено: \(attachment.name)", systemImage: "doc.badge.minus")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("message-attachment-removed")
            } else if let url = ChatAttachments.url(for: attachment), FileManager.default.fileExists(atPath: url.path) {
                Button {
                    do {
                        let item = try AttachmentPreviewItem(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, url: url)
                        previewCopy = item.url; preview = item
                    } catch { previewError = error.localizedDescription }
                } label: {
                    if attachment.mimeType.hasPrefix("image/"), let image = AttachmentThumbnail.image(url: url, maximumPixels: 512) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        Label(attachment.name, systemImage: "doc.text")
                            .font(.subheadline).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Открыть вложение \(attachment.name)")
                .accessibilityIdentifier("message-attachment")
            } else {
                Label("Вложение недоступно: \(attachment.name)", systemImage: "doc.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fullScreenCover(item: $preview, onDismiss: {
            AttachmentPreviewItem.removeOwnedCopy(previewCopy)
            previewCopy = nil
        }) { AttachmentPreview(item: $0) }
        .alert("Не удалось открыть вложение", isPresented: Binding(get: { previewError != nil }, set: { if !$0 { previewError = nil } })) {
            Button("Понятно", role: .cancel) { previewError = nil }
        } message: { Text(previewError ?? "") }
    }
}

private enum AttachmentThumbnail {
    static func image(data: Data, maximumPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maximumPixels: maximumPixels)
    }
    static func image(url: URL, maximumPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maximumPixels: maximumPixels)
    }
    private static func thumbnail(_ source: CGImageSource, maximumPixels: Int) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct AttachmentChip: View {
    let name: String
    let image: UIImage?
    var body: some View {
        HStack(spacing: 7) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
            } else { Image(systemName: "doc.text").font(.title3).frame(width: 28) }
            Text(name).font(.caption).lineLimit(1).frame(maxWidth: 125)
        }
        .frame(height: 48)
    }
}

private struct AttachmentPreviewItem: Identifiable {
    let id: UUID
    let name: String
    let mimeType: String
    let url: URL
    init(id: UUID, name: String, mimeType: String, url: URL) throws {
        let copy = try Self.previewURL(id: id, name: name, mimeType: mimeType)
        try FileManager.default.copyItem(at: url, to: copy)
        self.id = id; self.name = name; self.mimeType = mimeType; self.url = copy
    }
    static func removeOwnedCopy(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().standardizedFileURL.path == FileManager.default.temporaryDirectory.appending(path: "FindyAttachmentPreviews", directoryHint: .isDirectory).standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private static func previewURL(id: UUID, name: String, mimeType: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FindyAttachmentPreviews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = mimeType == "image/png" ? "png" : mimeType == "image/jpeg" ? "jpg" : "txt"
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let url = directory.appending(path: id.uuidString + "-" + base + "." + ext)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        return url
    }
    init(attachment: AssistantAttachment) throws {
        let url = try Self.previewURL(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType)
        try attachment.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.id = attachment.id; self.name = attachment.name; self.mimeType = attachment.mimeType; self.url = url
    }
}

private struct AttachmentPreview: View {
    let item: AttachmentPreviewItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if item.mimeType.hasPrefix("image/"), let image = UIImage(contentsOfFile: item.url.path) {
            GeneratedImageViewer(image: image, url: item.url)
        } else {
            NavigationStack {
                ScrollView { Text((try? String(contentsOf: item.url, encoding: .utf8)) ?? "Не удалось открыть файл.").textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                    .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                        ToolbarItem(placement: .primaryAction) { ShareLink(item: item.url) { Label("Поделиться", systemImage: "square.and.arrow.up") } }
                    }
            }
        }
    }
}

private struct AttachmentCamera: UIViewControllerRepresentable {
    let onComplete: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (Data?) -> Void
        init(onComplete: @escaping (Data?) -> Void) { self.onComplete = onComplete }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onComplete(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onComplete((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }
    }
}

private enum AttachmentUIError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Не удалось загрузить фото. Проверьте доступ к оригиналу и попробуйте ещё раз." }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
private enum AttachmentUIFixture {
    static func photo() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
    }
}
#endif
