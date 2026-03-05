import QuickLookThumbnailing
import AppKit
import NEFViewerCore
import os.log

private let logger = Logger(subsystem: "com.nefviewer.app.ThumbnailExtension",
                            category: "ThumbnailProvider")

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let scale = request.scale
        let maxPixel = max(request.maximumSize.width, request.maximumSize.height) * scale

        logger.info("provideThumbnail called for \(fileURL.lastPathComponent) maxSize=\(request.maximumSize.width)x\(request.maximumSize.height) scale=\(scale)")

        do {
            let jpegData = try NEFParser.extractEmbeddedJPEG(at: fileURL)
            logger.info("Extracted JPEG: \(jpegData.count) bytes")

            guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            else {
                logger.error("Failed to create CGImage from JPEG data")
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }

            let imgW = CGFloat(cgImage.width)
            let imgH = CGFloat(cgImage.height)
            let aspect = imgW / imgH

            let thumbSize: CGSize
            if aspect >= 1.0 {
                let w = min(request.maximumSize.width, imgW / scale)
                thumbSize = CGSize(width: w, height: w / aspect)
            } else {
                let h = min(request.maximumSize.height, imgH / scale)
                thumbSize = CGSize(width: h * aspect, height: h)
            }

            logger.info("Thumbnail contextSize=\(thumbSize.width)x\(thumbSize.height)")

            let reply = QLThumbnailReply(contextSize: thumbSize) { context in
                let pixelRect = CGRect(origin: .zero,
                                       size: CGSize(width: thumbSize.width * scale,
                                                    height: thumbSize.height * scale))
                context.draw(cgImage, in: pixelRect)
                return true
            }
            handler(reply, nil)

        } catch {
            logger.error("NEFParser failed: \(error.localizedDescription), trying fallback")
            self.fallbackCoreImageThumbnail(url: fileURL, size: request.maximumSize,
                                            handler: handler)
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
