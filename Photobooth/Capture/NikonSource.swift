import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import QuartzCore
import AppKit
import Foundation

/// Nikon D5500 (and similar Nikon DSLR) capture source, driven over PTP by
/// libgphoto2. Fulfils the same `CaptureSource` contract as the webcam:
///
///   • Preview — a liveview poll loop calls `gp_camera_capture_preview` (a ~640×424
///     JPEG per round-trip) and pushes each frame into a plain `CALayer`.
///   • Clips — the before/after "videos" are a recording of that same liveview
///     stream (a Nikon body can't start its *internal* movie recording over USB),
///     encoded to H.264 via `AVAssetWriter`. Video-only; liveview carries no audio.
///   • Still — a full-resolution mechanical-shutter capture (`gp_camera_capture`)
///     downloaded over USB. Firing it briefly interrupts liveview, which reads as a
///     natural freeze at the flash moment.
///
/// libgphoto2 holds a single camera handle that is NOT thread-safe, so every call
/// that touches it (preview polls, still capture, config) is serialized on one
/// private queue.
///
/// Requires `brew install libgphoto2`. On macOS the system `ptpcamerad` daemon
/// grabs the camera the moment it's plugged in; we kill it before opening so
/// `gp_camera_init` can claim the USB device.
final class NikonSource: CaptureSource {
    let id: String
    let displayName: String
    /// Mirror the feed horizontally (selfie/"mirror" feel), matching WebcamSource.
    /// Applied at the pixel level so preview, clips, and stills all agree.
    private let mirrored: Bool

    /// Serial queue owning the libgphoto2 handle. All camera calls run here.
    private let cameraQueue = DispatchQueue(label: "photobooth.nikon.camera")

    private var camera: UnsafeMutablePointer<Camera>?
    private var context: OpaquePointer?  // GPContext*
    private var isRunning = false

    // Preview
    private let previewLayer = CALayer()
    private var lastFrameSize = CGSize(width: 640, height: 424)

    /// Downscale the 24 MP (6000×4000) full-res still to this longer-edge size
    /// before handing it downstream. The printed strip is only 1200 px wide, so
    /// the native file just wastes disk and forces ~100 MB of decoded pixels per
    /// photo through the renderer. 2400 px keeps plenty of print headroom.
    var stillMaxLongEdge = 2400

    // Recording state — touched from the camera queue (appends) and callers
    // (start/stop). Guarded by `lock`.
    private let lock = NSLock()
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var sessionStarted = false
    private var recordingStart: CFTimeInterval = 0

    init(id: String = "nikon-gphoto2", displayName: String = "Nikon (gPhoto2)", mirrored: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.mirrored = mirrored
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsGravity = .resizeAspectFill
    }

    // MARK: - Session lifecycle

    func startSession() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cameraQueue.async {
                do {
                    try self.openCamera()
                    self.isRunning = true
                    cont.resume()
                    self.scheduleNextPreviewFrame()
                } catch {
                    self.closeCamera()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stopSession() {
        cameraQueue.async {
            self.isRunning = false
            self.closeCamera()
        }
    }

    /// Open the camera handle: release the macOS PTP daemon, point libgphoto2 at
    /// its Homebrew plugin dirs, init, and apply the photobooth capture config.
    private func openCamera() throws {
        Self.configurePluginPaths()
        Self.releaseSystemPTPDaemon()

        var cam: UnsafeMutablePointer<Camera>?
        guard gp_camera_new(&cam) == GP_OK, let cam else {
            throw CaptureError.deviceUnavailable("could not allocate camera handle")
        }
        let ctx = gp_context_new()

        // First init can lose the race with a daemon that re-grabbed the device;
        // kill it again and retry once.
        var rc = gp_camera_init(cam, ctx)
        if rc != GP_OK {
            Self.releaseSystemPTPDaemon()
            rc = gp_camera_init(cam, ctx)
        }
        guard rc == GP_OK else {
            gp_camera_free(cam)
            gp_context_unref(ctx)
            let msg = String(cString: gp_result_as_string(rc))
            throw CaptureError.deviceUnavailable("could not open \(displayName) (\(msg)). Is another app (Image Capture/Photos) using it?")
        }

        self.camera = cam
        self.context = ctx

        // JPEG-only so a single full-res file downloads (the D5500 often ships in
        // RAW+JPEG, which would download a ~22 MB NEF too). autofocus=Off tells
        // gphoto2 not to demand an AF lock before firing — the lens must be on M.
        setConfig("imagequality", "JPEG Fine")
        setConfig("autofocus", "Off")
    }

    private func closeCamera() {
        if let camera, let context {
            gp_camera_exit(camera, context)
            gp_camera_free(camera)
        }
        if let context { gp_context_unref(context) }
        camera = nil
        context = nil
    }

    // MARK: - Preview loop

    func makePreviewLayer() -> CALayer { previewLayer }

    /// Grab one liveview frame, then re-enqueue. Re-enqueuing via `async` yields
    /// the serial queue between frames so `captureStill` can interleave.
    private func scheduleNextPreviewFrame() {
        cameraQueue.async { [weak self] in
            guard let self, self.isRunning, let camera = self.camera, let context = self.context else { return }
            if let cg = self.grabPreviewFrame(camera: camera, context: context) {
                self.withLock { self.lastFrameSize = CGSize(width: cg.width, height: cg.height) }
                self.presentPreview(cg)
                self.appendToRecording(cg)
            } else {
                // Liveview briefly drops (e.g. during a still). Back off so a
                // transient error doesn't spin the queue.
                usleep(120_000)
            }
            if self.isRunning { self.scheduleNextPreviewFrame() }
        }
    }

    private func grabPreviewFrame(camera: UnsafeMutablePointer<Camera>, context: OpaquePointer) -> CGImage? {
        var file: OpaquePointer?
        guard gp_file_new(&file) == GP_OK, let file else { return nil }
        defer { gp_file_unref(file) }
        guard gp_camera_capture_preview(camera, file, context) == GP_OK else { return nil }
        guard let cg = Self.cgImage(fromCameraFile: file) else { return nil }
        return mirrored ? Self.flippedHorizontally(cg) : cg
    }

    private func presentPreview(_ cg: CGImage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.previewLayer.contents = cg
            CATransaction.commit()
        }
    }

    // MARK: - Recording (liveview → H.264)

    func startRecording(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let size = withLock { lastFrameSize }
        let width = Int(size.width) & ~1   // H.264 wants even dimensions
        let height = Int(size.height) & ~1

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: max(width, 2),
            AVVideoHeightKey: max(height, 2)
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: max(width, 2),
                kCVPixelBufferHeightKey as String: max(height, 2)
            ]
        )
        if writer.canAdd(vInput) { writer.add(vInput) }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "could not start writer")
        }

        withLock {
            self.writer = writer
            self.videoInput = vInput
            self.pixelAdaptor = adaptor
            self.sessionStarted = false
            self.isRecording = true
        }
    }

    /// Encode one liveview frame into the in-flight clip. Called from the preview
    /// loop on the camera queue.
    private func appendToRecording(_ cg: CGImage) {
        let (recording, writer, input, adaptor) = withLock {
            (isRecording, self.writer, self.videoInput, self.pixelAdaptor)
        }
        guard recording, let writer, let input, let adaptor, writer.status == .writing else { return }
        guard let pool = adaptor.pixelBufferPool, let pb = Self.pixelBuffer(from: cg, pool: pool) else { return }

        let now = CACurrentMediaTime()
        withLock {
            guard isRecording, writer.status == .writing else { return }
            if !sessionStarted {
                sessionStarted = true
                recordingStart = now
                writer.startSession(atSourceTime: .zero)
            }
            let pts = CMTime(seconds: max(0, now - recordingStart), preferredTimescale: 600)
            if input.isReadyForMoreMediaData {
                adaptor.append(pb, withPresentationTime: pts)
            }
        }
    }

    func stopRecording() async throws {
        let (writer, input): (AVAssetWriter?, AVAssetWriterInput?) = withLock {
            isRecording = false
            let w = self.writer; let v = self.videoInput
            self.writer = nil; self.videoInput = nil; self.pixelAdaptor = nil
            return (w, v)
        }
        guard let writer else { return }
        input?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - Still capture

    func captureStill() async throws -> CGImage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            cameraQueue.async {
                guard let camera = self.camera, let context = self.context else {
                    cont.resume(throwing: CaptureError.deviceUnavailable(self.displayName)); return
                }
                var path = CameraFilePath()
                let rc = gp_camera_capture(camera, GP_CAPTURE_IMAGE, &path, context)
                guard rc == GP_OK else {
                    let msg = String(cString: gp_result_as_string(rc))
                    cont.resume(throwing: CaptureError.deviceUnavailable(
                        "full-res capture failed (\(msg)). Set the lens switch to M (manual focus) and make sure the scene is exposed."))
                    return
                }

                let folder = Self.string(fromCArray: path.folder)
                let name = Self.string(fromCArray: path.name)

                var file: OpaquePointer?
                guard gp_file_new(&file) == GP_OK, let file else {
                    cont.resume(throwing: CaptureError.noFrameAvailable); return
                }
                defer { gp_file_unref(file) }

                let getRC = folder.withCString { f in
                    name.withCString { n in
                        gp_camera_file_get(camera, f, n, GP_FILE_TYPE_NORMAL, file, context)
                    }
                }
                // Tidy up the card so a long booth session doesn't fill it.
                _ = folder.withCString { f in name.withCString { n in gp_camera_file_delete(camera, f, n, context) } }

                guard getRC == GP_OK, let cg = Self.cgImage(fromCameraFile: file, maxLongEdge: self.stillMaxLongEdge) else {
                    cont.resume(throwing: CaptureError.noFrameAvailable); return
                }
                cont.resume(returning: self.mirrored ? Self.flippedHorizontally(cg) : cg)
            }
        }
    }

    // MARK: - Config helper

    /// Set a camera config leaf by name to a string value (radio/menu/text).
    /// Best-effort: config the body rejects (e.g. read-only) is logged, not fatal.
    private func setConfig(_ name: String, _ value: String) {
        guard let camera, let context else { return }
        var widget: OpaquePointer?
        guard gp_camera_get_single_config(camera, name, &widget, context) == GP_OK, let widget else { return }
        defer { gp_widget_free(widget) }
        _ = value.withCString { gp_widget_set_value(widget, $0) }
        _ = gp_camera_set_single_config(camera, name, widget, context)
    }

    // MARK: - libgphoto2 environment

    /// libgphoto2 finds its camera/port driver plugins via CAMLIBS/IOLIBS. Point
    /// them at the Homebrew install, resolving the versioned subdir at runtime so
    /// a libgphoto2 upgrade doesn't break us.
    static func configurePluginPaths() {
        let lib = "/opt/homebrew/opt/libgphoto2/lib"
        if let camlibs = firstSubdirectory(of: "\(lib)/libgphoto2") { setenv("CAMLIBS", camlibs, 1) }
        if let iolibs = firstSubdirectory(of: "\(lib)/libgphoto2_port") { setenv("IOLIBS", iolibs, 1) }
    }

    private static func firstSubdirectory(of path: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        guard let sub = entries.sorted().first else { return nil }
        return "\(path)/\(sub)"
    }

    /// Kill the macOS PTP daemon so it releases its USB claim on the camera.
    private static func releaseSystemPTPDaemon() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["ptpcamerad", "PTPCamera"]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        usleep(300_000) // let the USB claim actually free
    }

    // MARK: - Image plumbing

    /// Extract the JPEG bytes from a libgphoto2 CameraFile and decode to a CGImage.
    /// When `maxLongEdge` is set, decode a downscaled image whose longer edge is at
    /// most that many pixels (ImageIO does this without fully decoding the 24 MP).
    private static func cgImage(fromCameraFile file: OpaquePointer, maxLongEdge: Int? = nil) -> CGImage? {
        var ptr: UnsafePointer<CChar>?
        var size: UInt = 0
        guard gp_file_get_data_and_size(file, &ptr, &size) == GP_OK, let ptr, size > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(size))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let maxLongEdge {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return thumb }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func flippedHorizontally(_ cg: CGImage) -> CGImage {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return cg }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    private static func pixelBuffer(from cg: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        return pb
    }

    /// Read a NUL-terminated C string out of an imported fixed-size C char array
    /// (e.g. `CameraFilePath.name`, which Swift sees as a big tuple of CChar).
    private static func string<T>(fromCArray tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
