import AVFoundation
import CoreGraphics

/// A camera input the photobooth can drive. v1 is the webcam (AVFoundation);
/// a Nikon (libgphoto2) implementation slots in behind the same protocol later.
protocol CaptureSource: AnyObject {
    /// Stable identifier of the underlying device (e.g. AVCaptureDevice.uniqueID).
    var id: String { get }
    /// Human-readable name shown in the picker.
    var displayName: String { get }

    /// Begin delivering preview frames. Safe to call once; idempotent.
    func startSession() async throws
    func stopSession()

    /// A layer that renders the live feed continuously (independent of recording).
    func makePreviewLayer() -> CALayer

    /// Start recording a video clip to `url`. Recording shares the same stream
    /// that drives the preview so before/photo/after stay perfectly continuous.
    func startRecording(to url: URL) throws
    /// Stop the in-flight recording and resolve once the file is finalized.
    func stopRecording() async throws

    /// Grab the current frame as a still image.
    func captureStill() async throws -> CGImage
}

enum CaptureError: LocalizedError {
    case notAuthorized
    case noDevice
    case deviceUnavailable(String)
    case noFrameAvailable
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera or microphone access was denied. Grant access in System Settings ▸ Privacy & Security."
        case .noDevice: return "No camera device was found."
        case .deviceUnavailable(let s): return "Camera unavailable: \(s)"
        case .noFrameAvailable: return "No camera frame is available yet."
        case .writerFailed(let s): return "Recording failed: \(s)"
        }
    }
}
