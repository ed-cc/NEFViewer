import AppKit
import NEFViewerCore
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var fileURL: URL?
    @Published var image: NSImage?
    @Published var metadata: NEFMetadata?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(exportedAs: "com.nikon.raw-image")
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        // Idempotent for the same URL while already loading
        guard url != fileURL || !isLoading else { return }

        fileURL = url
        image = nil
        metadata = nil
        errorMessage = nil
        isLoading = true

        Task.detached(priority: .userInitiated) {
            do {
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: url)
                guard let nsImage = NSImage(data: jpegData) else {
                    throw NEFParserError.readError("Failed to decode JPEG")
                }
                let meta = try? MetadataReader.read(from: url)
                await MainActor.run {
                    self.image = nsImage
                    self.metadata = meta
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
