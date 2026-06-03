import AVFoundation
import CoreImage
import CoreGraphics
import AppKit

/// AVFoundation-backed webcam source.
///
/// One `AVCaptureSession` drives everything:
///   • `AVCaptureVideoPreviewLayer` renders the always-on live feed.
///   • `AVCaptureVideoDataOutput` keeps the latest frame (for stills) and, while
///     recording, feeds an `AVAssetWriter`.
///   • `AVCaptureAudioDataOutput` feeds the writer's audio track.
///
/// Keeping the still and the before/after clips on the same stream guarantees
/// they are perfectly continuous.
final class WebcamSource: NSObject, CaptureSource {
    let id: String
    let displayName: String

    private let device: AVCaptureDevice
    private let includeAudio: Bool
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "photobooth.capture.samples")
    private let ciContext = CIContext()

    // State touched from both the sample queue and callers — guarded by `lock`.
    private let lock = NSLock()
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    private var latestPixelBuffer: CVPixelBuffer?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isRecording = false

    init(device: AVCaptureDevice, includeAudio: Bool) {
        self.device = device
        self.id = device.uniqueID
        self.displayName = device.localizedName
        self.includeAudio = includeAudio
        super.init()
    }

    // MARK: - Session lifecycle

    func startSession() async throws {
        try await Self.authorize(.video)
        if includeAudio { try await Self.authorize(.audio) }

        try configureSession()
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        // Video input
        guard let videoInputDevice = try? AVCaptureDeviceInput(device: device) else {
            throw CaptureError.deviceUnavailable(displayName)
        }
        if session.canAddInput(videoInputDevice) { session.addInput(videoInputDevice) }

        // Audio input (optional)
        if includeAudio, let mic = AVCaptureDevice.default(for: .audio),
           let audioInputDevice = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInputDevice) {
            session.addInput(audioInputDevice)
        }

        // Video data output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Audio data output
        if includeAudio {
            audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
    }

    func makePreviewLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: - Recording

    func startRecording(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Size from the latest frame, falling back to a sane default.
        var width = 1280, height = 720
        lock.lock()
        if let pb = latestPixelBuffer {
            width = CVPixelBufferGetWidth(pb)
            height = CVPixelBufferGetHeight(pb)
        }
        lock.unlock()

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }

        var aInput: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); aInput = ai }
        }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "could not start writer")
        }

        lock.lock()
        self.writer = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.sessionStarted = false
        self.isRecording = true
        lock.unlock()
    }

    func stopRecording() async throws {
        let (writer, vInput, aInput): (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?) = withLock {
            isRecording = false
            let w = self.writer; let v = self.videoInput; let a = self.audioInput
            self.writer = nil; self.videoInput = nil; self.audioInput = nil
            return (w, v, a)
        }

        guard let writer else { return }
        vInput?.markAsFinished()
        aInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - Still capture

    func captureStill() async throws -> CGImage {
        // Wait briefly for at least one frame to arrive.
        for _ in 0..<30 {
            let pb = withLock { latestPixelBuffer }
            if let pb, let cg = cgImage(from: pb) { return cg }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        throw CaptureError.noFrameAvailable
    }

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Authorization

    private static func authorize(_ type: AVMediaType) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: type)
            if !granted { throw CaptureError.notAuthorized }
        default:
            throw CaptureError.notAuthorized
        }
    }
}

extension WebcamSource: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput

        if isVideo, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lock.lock()
            latestPixelBuffer = pb
            lock.unlock()
        }

        // Feed the writer while recording.
        lock.lock()
        let recording = isRecording
        let writer = self.writer
        let vInput = self.videoInput
        let aInput = self.audioInput
        var startNow = false
        if recording, let writer, !sessionStarted, isVideo, writer.status == .writing {
            sessionStarted = true
            startNow = true
        }
        let started = sessionStarted
        lock.unlock()

        guard recording, let writer, writer.status == .writing else { return }

        if startNow {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        guard started else { return }

        if isVideo {
            if let vInput, vInput.isReadyForMoreMediaData {
                vInput.append(sampleBuffer)
            }
        } else {
            if let aInput, aInput.isReadyForMoreMediaData {
                aInput.append(sampleBuffer)
            }
        }
    }
}
