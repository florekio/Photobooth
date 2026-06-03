import Foundation

/// Loads and manages past photobooth sessions saved under `~/Pictures/Photobooth`.
enum SessionLibrary {
    /// All past sessions, newest first. A folder counts as a session if it has
    /// at least one `photo_*.jpg`.
    static func load() -> [SessionResult] {
        guard let base = try? SessionStore.baseDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }

        let sessions = entries.compactMap { url -> SessionResult? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            return result(forFolder: url)
        }
        return sessions.sorted { $0.store.startedAt > $1.store.startedAt }
    }

    /// Build a `SessionResult` from an existing folder, including only files
    /// that actually exist.
    static func result(forFolder url: URL) -> SessionResult? {
        let store = SessionStore(existing: url)
        let fm = FileManager.default
        func existing(_ u: URL) -> URL? { fm.fileExists(atPath: u.path) ? u : nil }

        let photos = (1...StripLayout.count).compactMap { existing(store.photoURL($0)) }
        guard !photos.isEmpty else { return nil }

        return SessionResult(
            store: store,
            photos: photos,
            befores: (1...StripLayout.count).compactMap { existing(store.beforeURL($0)) },
            afters: (1...StripLayout.count).compactMap { existing(store.afterURL($0)) },
            montage: existing(store.montageURL),
            stripPDF: existing(store.stripPDFURL),
            stripPNG: existing(store.stripPNGURL),
            frameURL: store.loadFrameRef()
        )
    }

    /// Permanently delete a session folder.
    static func delete(_ session: SessionResult) throws {
        try FileManager.default.removeItem(at: session.store.root)
    }
}
