import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owns the on-disk folder for one photobooth session and the file naming.
///
/// Layout: `~/Pictures/Photobooth/<timestamp>/`
///   photo_1..N.jpg, before_1..N.mov, after_1..N.mov, montage.mp4, strip.pdf/png
struct SessionStore {
    let root: URL
    let startedAt: Date

    init() throws {
        let now = Date()
        self.startedAt = now
        let pictures = try FileManager.default.url(
            for: .picturesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = pictures.appendingPathComponent("Photobooth", isDirectory: true)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = base.appendingPathComponent(fmt.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.root = folder
    }

    func photoURL(_ index: Int) -> URL { root.appendingPathComponent("photo_\(index).jpg") }
    func beforeURL(_ index: Int) -> URL { root.appendingPathComponent("before_\(index).mov") }
    func afterURL(_ index: Int) -> URL { root.appendingPathComponent("after_\(index).mov") }
    var montageURL: URL { root.appendingPathComponent("montage.mp4") }
    var stripPDFURL: URL { root.appendingPathComponent("strip.pdf") }
    var stripPNGURL: URL { root.appendingPathComponent("strip.png") }

    /// Persist a captured still as JPEG.
    @discardableResult
    func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.9) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError.writerFailed("could not create JPEG destination")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.writerFailed("could not finalize JPEG")
        }
        return url
    }
}
