import Foundation

/// Stitches the captured clips and photos into one shareable MP4:
/// for each shot → before clip, a ~1.5s freeze of the photo, the after clip.
///
/// Two-step for reliability: every segment is first re-encoded to identical
/// parameters (1280×720, 30fps, H.264 + AAC), then joined with the concat
/// demuxer using stream copy.
struct MontageBuilder {
    var width = 1280
    var height = 720
    var fps = 30
    var photoHoldSeconds = 1.5

    private let ffmpeg: URL
    private let ffprobe: URL

    init() throws {
        ffmpeg = try Self.locate("ffmpeg")
        ffprobe = try Self.locate("ffprobe")
    }

    func build(_ result: SessionResult) async throws -> URL {
        let work = result.store.root.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var segments: [URL] = []
        for i in result.photos.indices {
            let shot = i + 1
            segments.append(try await encodeClip(result.befores[i], to: work.appendingPathComponent("seg_\(shot)_before.mp4")))
            segments.append(try await encodePhoto(result.photos[i], to: work.appendingPathComponent("seg_\(shot)_photo.mp4")))
            segments.append(try await encodeClip(result.afters[i], to: work.appendingPathComponent("seg_\(shot)_after.mp4")))
        }

        return try await concat(segments, to: result.store.montageURL)
    }

    // MARK: - Segment encoders

    private var videoFilter: String {
        "scale=\(width):\(height):force_original_aspect_ratio=decrease," +
        "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p"
    }

    private func encodeClip(_ input: URL, to output: URL) async throws -> URL {
        let hasAudio = await clipHasAudio(input)
        var args = ["-y", "-i", input.path]
        if !hasAudio {
            args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100"]
        }
        args += [
            "-map", "0:v:0",
            "-map", hasAudio ? "0:a:0" : "1:a:0",
            "-vf", videoFilter,
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ar", "44100", "-ac", "2",
            "-shortest", output.path
        ]
        try await run(ffmpeg, args)
        return output
    }

    private func encodePhoto(_ input: URL, to output: URL) async throws -> URL {
        let args = [
            "-y",
            "-loop", "1", "-t", String(photoHoldSeconds), "-i", input.path,
            "-f", "lavfi", "-t", String(photoHoldSeconds),
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-vf", videoFilter,
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ar", "44100", "-ac", "2",
            "-shortest", output.path
        ]
        try await run(ffmpeg, args)
        return output
    }

    private func concat(_ segments: [URL], to output: URL) async throws -> URL {
        let listURL = output.deletingLastPathComponent().appendingPathComponent("concat_list.txt")
        let body = segments.map { "file '\($0.path)'" }.joined(separator: "\n")
        try body.write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }

        try await run(ffmpeg, [
            "-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-c", "copy", "-movflags", "+faststart", output.path
        ])
        return output
    }

    // MARK: - ffprobe / process helpers

    private func clipHasAudio(_ url: URL) async -> Bool {
        let out = try? await run(ffprobe, [
            "-v", "error", "-select_streams", "a",
            "-show_entries", "stream=codec_type", "-of", "csv=p=0", url.path
        ], captureStdout: true)
        return (out?.contains("audio") ?? false)
    }

    @discardableResult
    private func run(_ tool: URL, _ args: [String], captureStdout: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outData = captureStdout ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(throwing: CaptureError.writerFailed(
                        "\(tool.lastPathComponent) failed: \(msg.suffix(500))"))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
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
