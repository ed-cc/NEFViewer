import AppKit
import SwiftUI

// MARK: - Zoom action enum

enum ZoomAction: Equatable {
    case none
    case zoomIn
    case zoomOut
    case fitToWindow
    case actualSize
}

// MARK: - Free function shared by performZoom and Coordinator

private func pixelSize(of image: NSImage?) -> CGSize {
    guard let image else { return .zero }
    if let rep = image.representations.first {
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return image.size
}

private func fitMagnification(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
    guard imageSize.width > 0, imageSize.height > 0,
          viewSize.width > 0, viewSize.height > 0 else { return 1 }
    return min(
        viewSize.width / imageSize.width,
        viewSize.height / imageSize.height
    )
}

// MARK: - SwiftUI wrapper

struct ScrollableImageView: NSViewRepresentable {

    let image: NSImage?
    @Binding var zoomAction: ZoomAction

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 20
        scrollView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.drawsBackground = true

        // Centering clip view
        let clipView = CenteringClipView()
        scrollView.contentView = clipView
        clipView.postsBoundsChangedNotifications = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.animates = false

        scrollView.documentView = imageView

        context.coordinator.scrollView = scrollView

        // Double-click zoom toggle
        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)

        // Observe clip view frame changes for re-fit on resize
        let coordinator = context.coordinator
        clipView.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak coordinator, weak scrollView] _ in
            guard let coordinator, let scrollView else { return }
            coordinator.refitIfNeeded(scrollView: scrollView)
        }

        // Track user-initiated pinch zoom so isFitted stays accurate
        coordinator.magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.isFitted = false
        }

        // Track scroll-wheel zoom (magnification changes without live magnify)
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak coordinator, weak scrollView] _ in
            guard let coordinator, let scrollView else { return }
            guard coordinator.isFitted else { return }
            if abs(scrollView.magnification - coordinator.fitMag) > 0.001 {
                coordinator.isFitted = false
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {

        guard let imageView = scrollView.documentView as? NSImageView else { return }

        // New image loaded
        if imageView.image !== image {

            imageView.image = image

            let size = pixelSize(of: image)
            imageView.frame = CGRect(origin: .zero, size: size)

            // Fit new image to window after layout
            if image != nil {
                DispatchQueue.main.async {
                    let viewSize = scrollView.contentView.bounds.size
                    let fit = fitMagnification(imageSize: size, viewSize: viewSize)
                    scrollView.magnification = fit
                    context.coordinator.fitMag = fit
                    context.coordinator.isFitted = true
                }
            }
        }

        // Handle toolbar / keyboard zoom
        if zoomAction != .none {

            let action = zoomAction

            DispatchQueue.main.async {

                zoomAction = .none

                performZoom(
                    action,
                    scrollView: scrollView,
                    coordinator: context.coordinator
                )
            }
        }
    }

    // MARK: - Zoom helpers

    func performZoom(
        _ action: ZoomAction,
        scrollView: NSScrollView,
        coordinator: Coordinator
    ) {

        let img = (scrollView.documentView as? NSImageView)?.image
        let imageSize = pixelSize(of: img)

        let viewSize = scrollView.contentView.bounds.size
        let fit = fitMagnification(imageSize: imageSize, viewSize: viewSize)

        switch action {

        case .none:
            break

        case .zoomIn:
            let newMag = min(scrollView.magnification * 1.5,
                             scrollView.maxMagnification)
            scrollView.animator().magnification = newMag
            coordinator.isFitted = false

        case .zoomOut:
            let newMag = max(scrollView.magnification / 1.5,
                             scrollView.minMagnification)
            scrollView.animator().magnification = newMag
            coordinator.isFitted = abs(newMag - fit) < 0.001

        case .fitToWindow:
            scrollView.animator().magnification = fit
            coordinator.fitMag = fit
            coordinator.isFitted = true

        case .actualSize:
            scrollView.animator().magnification = 1.0
            coordinator.isFitted = false
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {

        weak var scrollView: NSScrollView?
        var frameObserver: Any?
        var magnifyObserver: Any?
        var boundsObserver: Any?

        var fitMag: CGFloat = 1
        var isFitted = true

        deinit {
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = magnifyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func refitIfNeeded(scrollView: NSScrollView) {
            guard isFitted else { return }

            // If magnification diverged from fitMag (e.g. scroll-wheel zoom),
            // break out of fit mode instead of snapping back
            if abs(scrollView.magnification - fitMag) > 0.001 {
                isFitted = false
                return
            }

            guard let imageView = scrollView.documentView as? NSImageView,
                  let image = imageView.image else { return }

            let imageSize = pixelSize(of: image)
            let viewSize = scrollView.contentView.bounds.size
            let fit = fitMagnification(imageSize: imageSize, viewSize: viewSize)

            scrollView.magnification = fit
            fitMag = fit
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {

            guard let scrollView else { return }

            if isFitted {

                let click = gesture.location(in: scrollView.contentView)

                scrollView.setMagnification(1, centeredAt: click)

                isFitted = false

            } else {

                let img = (scrollView.documentView as? NSImageView)?.image
                let imageSize = pixelSize(of: img)

                let viewSize = scrollView.contentView.bounds.size
                let fit = fitMagnification(imageSize: imageSize, viewSize: viewSize)

                scrollView.animator().magnification = fit

                fitMag = fit
                isFitted = true
            }
        }
    }
}
