import AppKit

/// One image the user pasted into the composer but has not sent yet.
///
/// The bytes are already normalized (sRGB, longest edge capped) so the bridge
/// only has to base64 them for DSH's attachment admission.
struct ComposerImage: Identifiable {
    let id: UUID
    let data: Data
    let mediaType: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnail: NSImage?
}

/// Turns whatever the pasteboard holds into attachment-ready bytes.
enum ComposerImageEncoder {
    /// Longest edge in pixels. Screenshots are usually 2x Retina, and DSH's
    /// admission step would downscale anyway; capping here keeps the JSON body
    /// far below the bridge limit.
    static let maxEdge: CGFloat = 1600
    /// PNG above this size is re-encoded as JPEG so one screenshot cannot
    /// dominate the request body.
    static let maxPNGBytes = 4 * 1024 * 1024

    static func make(from image: NSImage, name: String) -> ComposerImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, maxEdge / max(width, height))
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let scaled = context.makeImage() else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: scaled)
        var data = bitmap.representation(using: .png, properties: [:])
        var mediaType = "image/png"
        if let png = data, png.count > maxPNGBytes,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mediaType = "image/jpeg"
        }
        guard let bytes = data else { return nil }

        let displayName: String
        if name.contains(".") {
            displayName = name
        } else {
            displayName = name + "." + (mediaType == "image/png" ? "png" : "jpg")
        }
        return ComposerImage(
            id: UUID(),
            data: bytes,
            mediaType: mediaType,
            name: displayName,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            thumbnail: NSImage(cgImage: scaled, size: NSSize(width: pixelWidth, height: pixelHeight))
        )
    }
}

/// Reads images out of a pasteboard: copied files first, then raw image data.
enum ComposerPasteboard {
    static func images(from pasteboard: NSPasteboard = .general) -> [(image: NSImage, name: String?)] {
        if let urls = fileURLs(from: pasteboard) {
            let files = ComposerDrop.acceptedFileURLs(urls).compactMap { url -> (image: NSImage, name: String?)? in
                guard let image = NSImage(contentsOf: url) else { return nil }
                return (image, url.lastPathComponent)
            }
            if !files.isEmpty { return files }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            return images.map { ($0, nil) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return [(image, nil)]
            }
        }
        return []
    }

    /// Cheap check used while a drag hovers over the composer: reads the
    /// promised file URLs but does not decode any image.
    static func hasImages(from pasteboard: NSPasteboard) -> Bool {
        if let urls = fileURLs(from: pasteboard), !ComposerDrop.acceptedFileURLs(urls).isEmpty {
            return true
        }
        return pasteboard.availableType(from: [.tiff, .png]) != nil
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}
