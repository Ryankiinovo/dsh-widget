import Foundation

/// Which dropped files the composer accepts.
///
/// The widget has no file-upload path: a dropped file can only become an
/// image attachment, so anything that is not an image is left to AppKit.
/// The extension list lives here, away from AppKit, so the unit tests can
/// exercise it without a window server.
enum ComposerDrop {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp",
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Keeps the image files, dropping folders and other file types.
    static func acceptedFileURLs(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && isImageFile($0) }
    }
}
