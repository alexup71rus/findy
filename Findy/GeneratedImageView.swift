import SwiftUI
import UIKit

struct GeneratedImageView: View {
    let messageID: UUID
    @ObservedObject private var media = MediaStorage.shared
    @State private var showingViewer = false
    var body: some View {
        let _ = media.revision
        if let url = GeneratedImages.url(for: messageID), let image = UIImage(contentsOfFile: url.path) {
            Button { showingViewer = true } label: {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 300, maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть изображение")
            .fullScreenCover(isPresented: $showingViewer) { GeneratedImageViewer(image: image, url: url) }
        } else if GeneratedImages.wasRemoved(for: messageID) {
            Label("Изображение удалено", systemImage: "photo.badge.minus").foregroundStyle(.secondary)
        } else if GeneratedImages.url(for: messageID) != nil {
            Label("Не удалось открыть изображение", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
        }
    }
}

struct GeneratedImageViewer: View {
    let image: UIImage
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZoomableImage(image: image).background(.black).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Изображение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: url) { Label("Поделиться или сохранить", systemImage: "square.and.arrow.up") } }
                }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        context.coordinator.imageView = view
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
