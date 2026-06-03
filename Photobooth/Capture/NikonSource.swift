import AVFoundation
import CoreGraphics

/// Placeholder for the Nikon D5500 path (Phase 4), driven by libgphoto2 over PTP.
///
/// Planned behaviour:
///   • Still capture: full-resolution PTP capture.
///   • Preview/recording: the camera's *internal* video recording cannot be
///     started over USB on Nikon bodies, so the before/after "videos" will be a
///     recording of the liveview stream (~720p MJPEG) instead.
///
/// Requires `brew install gphoto2 libgphoto2`. Not wired up yet.
final class NikonSource: CaptureSource {
    let id: String
    let displayName: String

    init(id: String = "nikon-gphoto2", displayName: String = "Nikon (gPhoto2)") {
        self.id = id
        self.displayName = displayName
    }

    private func unimplemented() -> CaptureError {
        .deviceUnavailable("Nikon support is not implemented yet (Phase 4).")
    }

    func startSession() async throws { throw unimplemented() }
    func stopSession() {}
    func makePreviewLayer() -> CALayer { CALayer() }
    func startRecording(to url: URL) throws { throw unimplemented() }
    func stopRecording() async throws { throw unimplemented() }
    func captureStill() async throws -> CGImage { throw unimplemented() }
}
