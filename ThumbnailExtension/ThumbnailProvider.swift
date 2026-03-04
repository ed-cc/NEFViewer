import QuickLookThumbnailing
import AppKit
import NEFViewerCore

// Phase 5 — full implementation with cache integration.
// This stub is wired end-to-end: it extracts the embedded JPEG from any NEF
// file (lossless, HE★, HE) via a ranged read of ~1–2 MB.
class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maxSize = request.maximumSize

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: fileURL)
                guard let image = NSImage(data: jpegData) else {
                    handler(nil, CocoaError(.fileReadCorruptFile))
                    return
                }
                let reply = QLThumbnailReply(contextSize: maxSize) { context in
                    let rect = CGRect(origin: .zero, size: maxSize)
                    if let cgImage = image.cgImage(forProposedRect: nil,
                                                   context: nil,
                                                   hints: nil) {
                        context.draw(cgImage, in: rect)
                    }
                    return true
                }
                handler(reply, nil)
            } catch {
                // Fallback: system Core Image RAW decode (works for lossless NEF)
                self.fallbackCoreImageThumbnail(url: fileURL, size: maxSize,
                                                handler: handler)
            }
        }
    }

    private func fallbackCoreImageThumbnail(
        url: URL,
        size: CGSize,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                options as CFDictionary)
        else {
            handler(nil, CocoaError(.fileReadUnsupportedScheme))
            return
        }
        let reply = QLThumbnailReply(contextSize: size) { context in
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
