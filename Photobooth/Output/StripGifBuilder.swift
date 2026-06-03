import CoreGraphics
import Foundation

/// Renders the "video photo strip" (the 4-cell `DigitalStripView` layout) into a
/// looping animated **GIF** via ffmpeg, so the phone share page can show the
/// moving strip without a video player. Each cell is that shot's before+after
/// clips concatenated and sped up slightly; cells are aspect-filled into the
/// same vertical `StripLayout` geometry as the printable strip, on white.
struct StripGifBuilder {
    /// Output width in px; height follows the strip geometry. Kept modest so the
    /// GIF stays a reasonable download over the tunnel.
    var outputWidth = 280
    var fps = 12
    /// Playback speed-up (matches the lively feel of the on-screen strip).
    var speed = 1.5
    /// Hard cap on GIF length (before+after ≈ 10s of source → ~6.7s at 1.5×).
    var maxDuration = 7.0

    private let ffmpeg: URL

    init() throws { ffmpeg = try Self.locate("ffmpeg") }

    /// Build `<session>/strip.gif`. Returns nil if there are no clips to render.
    func build(_ result: SessionResult, frame frameURL: URL?) async throws -> URL? {
        let scale = Double(outputWidth) / Double(StripLayout.designSize.width)
        func px(_ v: CGFloat) -> Int { Int((Double(v) * scale).rounded()) }

        let margin = px(StripLayout.margin)
        let gap = px(StripLayout.gap)
        let cellW = outputWidth - 2 * margin
        let cellH = px(StripLayout.cellSize.height)
        // Footer band plus the bottom margin, as one white strip at the bottom.
        let footerH = px(StripLayout.footerHeight + StripLayout.margin)

        let count = min(result.photos.count, StripLayout.count)
        guard count > 0 else { return nil }
        let height = margin + count * cellH + (count - 1) * gap + footerH

        // Per-cell source clips (before then after) that actually exist on disk.
        var cells: [[URL]] = []
        for i in 0..<count {
            var urls: [URL] = []
            if result.befores.indices.contains(i), exists(result.befores[i]) { urls.append(result.befores[i]) }
            if result.afters.indices.contains(i), exists(result.afters[i]) { urls.append(result.afters[i]) }
            cells.append(urls)
        }
        guard cells.contains(where: { !$0.isEmpty }) else { return nil }

        // Inputs: [0] white background, then each clip in cell order, then frame.
        var args = ["-y", "-f", "lavfi", "-t", String(maxDuration),
                    "-i", "color=c=white:s=\(outputWidth)x\(height):r=\(fps)"]
        var nextInput = 1
        var cellInputs: [[Int]] = []
        for urls in cells {
            var idxs: [Int] = []
            for url in urls { args += ["-i", url.path]; idxs.append(nextInput); nextInput += 1 }
            cellInputs.append(idxs)
        }
        var frameInput: Int?
        if let frameURL, exists(frameURL) {
            args += ["-i", frameURL.path]; frameInput = nextInput; nextInput += 1
        }

        // Build the filter graph (validated against ffmpeg).
        var fc = ""
        for (c, idxs) in cellInputs.enumerated() where !idxs.isEmpty {
            for gi in idxs {
                fc += "[\(gi):v]scale=\(cellW):\(cellH):force_original_aspect_ratio=increase," +
                      "crop=\(cellW):\(cellH),setsar=1,fps=\(fps),format=rgb24[v\(gi)];"
            }
            let labels = idxs.map { "[v\($0)]" }.joined()
            fc += "\(labels)concat=n=\(idxs.count):v=1:a=0,setpts=PTS/\(speed)[cell\(c)];"
        }

        var base = "0:v"
        for (c, idxs) in cellInputs.enumerated() where !idxs.isEmpty {
            let y = margin + c * (cellH + gap)
            fc += "[\(base)][cell\(c)]overlay=\(margin):\(y):eof_action=repeat[o\(c)];"
            base = "o\(c)"
        }

        if let fi = frameInput {
            fc += "[\(fi):v]scale=\(outputWidth):\(height)[frm];"
            fc += "[\(base)][frm]overlay=0:0[comp];"
            base = "comp"
        }

        fc += "[\(base)]split[pa][pb];[pa]palettegen=stats_mode=diff[pal];" +
              "[pb][pal]paletteuse=dither=bayer:bayer_scale=3[out]"

        let output = result.store.stripGIFURL
        args += ["-filter_complex", fc, "-map", "[out]", "-loop", "0", output.path]
        try await run(args)
        return output
    }

    // MARK: - Helpers

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func run(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = args
            let stderr = Pipe()
            process.standardError = stderr
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(throwing: CaptureError.writerFailed("ffmpeg gif failed: \(msg.suffix(500))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func locate(_ name: String) throws -> URL {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CaptureError.writerFailed("\(name) not found. Install it with: brew install ffmpeg")
    }
}
