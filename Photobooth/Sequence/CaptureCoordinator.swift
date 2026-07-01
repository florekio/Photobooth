import SwiftUI

/// Result of a finished session, handed to the output builders (Phase 3).
struct SessionResult {
    let store: SessionStore
    let photos: [URL]
    let befores: [URL]
    let afters: [URL]
    var montage: URL?
    var stripPDF: URL?
    var stripPNG: URL?
    /// Animated GIF of the digital (video) strip, shown on the phone share page.
    var stripGIF: URL?
    /// Decorative frame applied to the strip (nil = none).
    var frameURL: URL?
}

/// Drives the automatic 4-shot sequence:
/// per shot → 5s countdown (recording "before") → photo + flash → 5s "after".
@Observable
@MainActor
final class CaptureCoordinator {
    enum Phase: Equatable {
        case idle
        case countdown(shot: Int, remaining: Int)   // "before" clip recording
        case flash(shot: Int)
        case recordingAfter(shot: Int, remaining: Int)
        case getReady(nextShot: Int)
        case composing
        case done
        case failed(String)
    }

    struct Config {
        var shots = 4
        var countdownSeconds = 3
        var afterSeconds = 3
        var getReadySeconds = 2
    }

    private(set) var phase: Phase = .idle
    let config: Config
    var isRunning: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    private let source: CaptureSource
    private var task: Task<Void, Never>?

    /// Called on the main actor when the capture portion finishes. The
    /// controller wires this to the output builders in Phase 3.
    var onCaptured: ((SessionResult) async -> Void)?

    init(source: CaptureSource, config: Config = Config()) {
        self.source = source
        self.config = config
    }

    func start() {
        guard !isRunning else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { try? await source.stopRecording() }
        phase = .idle
    }

    private func run() async {
        do {
            let store = try SessionStore()
            var photos: [URL] = []

            for shot in 1...config.shots {
                try Task.checkCancellation()

                // "Before" clip + countdown.
                try source.startRecording(to: store.beforeURL(shot))
                for remaining in stride(from: config.countdownSeconds, through: 1, by: -1) {
                    phase = .countdown(shot: shot, remaining: remaining)
                    try await sleep(seconds: 1)
                }

                // Capture the still while the clip is still rolling, then stop.
                let image = try await source.captureStill()
                try store.writeJPEG(image, to: store.photoURL(shot))
                photos.append(store.photoURL(shot))

                phase = .flash(shot: shot)
                try await source.stopRecording()
                try await sleep(seconds: 0.25)

                // "After" clip.
                try source.startRecording(to: store.afterURL(shot))
                for remaining in stride(from: config.afterSeconds, through: 1, by: -1) {
                    phase = .recordingAfter(shot: shot, remaining: remaining)
                    try await sleep(seconds: 1)
                }
                try await source.stopRecording()

                if shot < config.shots {
                    phase = .getReady(nextShot: shot + 1)
                    try await sleep(seconds: Double(config.getReadySeconds))
                }
            }

            phase = .composing
            let result = SessionResult(
                store: store,
                photos: photos,
                befores: (1...config.shots).map { store.beforeURL($0) },
                afters: (1...config.shots).map { store.afterURL($0) }
            )
            await onCaptured?(result)
            phase = .done
        } catch is CancellationError {
            try? await source.stopRecording()
            phase = .idle
        } catch {
            try? await source.stopRecording()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Cancellation-aware sleep.
    private func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
