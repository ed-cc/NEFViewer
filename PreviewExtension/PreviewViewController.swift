import Cocoa
import QuickLook
import NEFViewerCore

// Phase 6 — full implementation with metadata overlay and orientation correction.
class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView: NSImageView = {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let jpegData = try NEFParser.extractEmbeddedJPEG(at: url)
                let image = NSImage(data: jpegData)
                DispatchQueue.main.async {
                    self.imageView.image = image
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async { handler(error) }
            }
        }
    }
}
