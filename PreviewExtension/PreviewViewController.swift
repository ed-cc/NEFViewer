import Cocoa
import QuickLookUI
import NEFViewerCore
import os.log

private let logger = Logger(subsystem: "com.nefviewer.app.PreviewExtension",
                            category: "PreviewViewController")

class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView: NSImageView = {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }()

    override func loadView() {
        let v = NSView()
        v.autoresizingMask = [.width, .height]
        v.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: v.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: url)
                logger.info("Extracted JPEG: \(jpegData.count) bytes from \(url.lastPathComponent)")

                guard let image = NSImage(data: jpegData) else {
                    DispatchQueue.main.async { handler(CocoaError(.fileReadCorruptFile)) }
                    return
                }

                let imgSize = image.size  // in points (== pixels for JPEG data)
                logger.info("Image size: \(imgSize.width)x\(imgSize.height) pt")

                // Scale to a reasonable point size for the Quick Look panel.
                // Quick Look interprets preferredContentSize in points, so
                // 6000x4000 would create an impossibly large panel.  Cap the
                // longest edge to 800 pt and preserve the aspect ratio.
                let maxEdge: CGFloat = 800
                let scale = min(maxEdge / max(imgSize.width, imgSize.height), 1.0)
                let panelSize = NSSize(
                    width: round(imgSize.width * scale),
                    height: round(imgSize.height * scale)
                )

                DispatchQueue.main.async {
                    self.preferredContentSize = panelSize
                    self.imageView.image = image
                    handler(nil)
                }
            } catch {
                logger.error("Failed: \(error.localizedDescription)")
                DispatchQueue.main.async { handler(error) }
            }
        }
    }
}
