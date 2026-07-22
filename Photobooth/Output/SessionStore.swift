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

    /// The shared `~/Pictures/Photobooth` directory holding every session folder.
    static var baseDirectory: URL {
        get throws {
            let pictures = try FileManager.default.url(
                for: .picturesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return pictures.appendingPathComponent("Photobooth", isDirectory: true)
        }
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Create a fresh, timestamped session folder.
    init() throws {
        let now = Date()
        self.startedAt = now
        let folder = try Self.baseDirectory.appendingPathComponent(
            Self.folderFormatter.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.root = folder
    }

    /// Reopen an existing session folder (used by the gallery). Date is parsed
    /// from the folder name, falling back to its creation date.
    init(existing root: URL) {
        self.root = root
        if let date = Self.folderFormatter.date(from: root.lastPathComponent) {
            self.startedAt = date
        } else {
            let values = try? root.resourceValues(forKeys: [.creationDateKey])
            self.startedAt = values?.creationDate ?? Date(timeIntervalSince1970: 0)
        }
    }

    func photoURL(_ index: Int) -> URL { root.appendingPathComponent("photo_\(index).jpg") }
    func beforeURL(_ index: Int) -> URL { root.appendingPathComponent("before_\(index).mov") }
    func afterURL(_ index: Int) -> URL { root.appendingPathComponent("after_\(index).mov") }
    var montageURL: URL { root.appendingPathComponent("montage.mp4") }
    var stripPDFURL: URL { root.appendingPathComponent("strip.pdf") }
    var stripPNGURL: URL { root.appendingPathComponent("strip.png") }
    /// Compressed JPEG of the strip for phone download/sharing (PNG is kept for
    /// lossless printing).
    var stripJPGURL: URL { root.appendingPathComponent("strip.jpg") }
    var stripGIFURL: URL { root.appendingPathComponent("strip.gif") }
    var frameRefURL: URL { root.appendingPathComponent("frame.txt") }

    /// Persist which frame was used, so the gallery can re-apply it.
    func saveFrameRef(_ url: URL?) {
        try? (url?.path ?? "").write(to: frameRefURL, atomically: true, encoding: .utf8)
    }

    /// Resolve the persisted frame: the stored path if it still exists, else a
    /// bundled frame matched by filename.
    func loadFrameRef() -> URL? {
        guard let raw = try? String(contentsOf: frameRefURL, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let name = (path as NSString).lastPathComponent
        return Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "png")
    }

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
