import SwiftUI
import AVFoundation
import AppKit

/// A selectable decorative frame for the strip. `url == nil` means "no frame".
struct FrameOption: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL?
}

/// UI-facing owner of the active capture source and device selection.
@Observable
@MainActor
final class CameraController {
    private(set) var devices: [CameraDevice] = []
    private(set) var selectedDeviceID: String?
    private(set) var source: CaptureSource?
    private(set) var previewLayer: CALayer?
    var includeAudio: Bool = true

    private(set) var coordinator: CaptureCoordinator?
    /// Most recent finished session, shown by ResultsView (Phase 3).
    var lastResult: SessionResult?

    var statusMessage: String?
    var showingGallery = false

    // Frames
    private(set) var frameOptions: [FrameOption] = [FrameOption(id: "none", name: "No frame", url: nil)]
    var selectedFrameID: String = "none"
    var selectedFrameURL: URL? { frameOptions.first(where: { $0.id == selectedFrameID })?.url }

    var isCapturing: Bool { coordinator?.isRunning ?? false }
    var shotCount: Int { coordinator?.config.shots ?? 4 }

    /// Discover bundled `frame-*.png` templates plus the built-in "No frame".
    func loadFrames() {
        var options: [FrameOption] = [FrameOption(id: "none", name: "No frame", url: nil)]
        let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasPrefix("frame-") {
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "frame-", with: "").capitalized
            options.append(FrameOption(id: url.lastPathComponent, name: name, url: url))
        }
        frameOptions = options
    }

    /// Pick a frame; if a result is already showing, re-render its printable
    /// strip so the change is visible immediately.
    func selectFrame(_ id: String) {
        selectedFrameID = id
        rerenderStripIfNeeded()
    }

    /// Let the user choose any PNG as a custom frame.
    func chooseCustomFrame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a frame PNG (ideal size 1200×3600, transparent windows)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let option = FrameOption(id: url.path, name: url.deletingPathExtension().lastPathComponent, url: url)
        frameOptions.removeAll { $0.id == option.id }
        frameOptions.append(option)
        selectFrame(option.id)
    }

    private func rerenderStripIfNeeded() {
        guard var result = lastResult else { return }
        do {
            let strip = try PhotoStripRenderer().render(result, frame: selectedFrameURL)
            result.stripPDF = strip.pdf
            result.stripPNG = strip.png
            result.frameURL = selectedFrameURL
            result.store.saveFrameRef(selectedFrameURL)
            lastResult = result
        } catch {
            statusMessage = "Photo strip failed: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        var found = DeviceDiscovery.webcams()
        // Nikon entry is always offered; selecting it surfaces the "not yet"
        // message until Phase 4 lands.
        found.append(CameraDevice(id: "nikon-gphoto2", name: "Nikon (gPhoto2)", kind: .nikon))
        devices = found
        if selectedDeviceID == nil {
            selectedDeviceID = found.first(where: { $0.kind == .webcam })?.id
        }
    }

    /// Activate the given device, tearing down any previous session.
    func select(deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        selectedDeviceID = deviceID
        await teardown()

        let newSource: CaptureSource
        switch device.kind {
        case .webcam:
            guard let av = DeviceDiscovery.avDevice(for: deviceID) else {
                statusMessage = "Could not open \(device.name)."
                return
            }
            newSource = WebcamSource(device: av, includeAudio: includeAudio)
        case .nikon:
            newSource = NikonSource(id: device.id, displayName: device.name)
        }

        do {
            try await newSource.startSession()
            source = newSource
            previewLayer = newSource.makePreviewLayer()
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            source = nil
            previewLayer = nil
        }
    }

    /// Open the first available webcam at launch.
    func start() async {
        loadFrames()
        refreshDevices()
        if let id = selectedDeviceID {
            await select(deviceID: id)
        } else {
            statusMessage = "No camera found. Connect a webcam and reopen the picker."
        }
    }

    private func teardown() async {
        coordinator?.cancel()
        coordinator = nil
        source?.stopSession()
        source = nil
        previewLayer = nil
    }

    // MARK: - Capture sequence

    /// Begin the automatic 4-shot sequence on the active source.
    func startCapture() {
        guard let source else {
            statusMessage = "No camera is active."
            return
        }
        guard coordinator?.isRunning != true else { return }
        lastResult = nil
        let coordinator = CaptureCoordinator(source: source)
        coordinator.onCaptured = { [weak self] result in
            await self?.handleCaptured(result)
        }
        self.coordinator = coordinator
        coordinator.start()
    }

    func cancelCapture() {
        coordinator?.cancel()
    }

    /// Build the montage MP4 and the printable photo strip, then surface the
    /// result for ResultsView. Output failures are reported but don't lose the
    /// captured media (the raw files are already on disk).
    private func handleCaptured(_ result: SessionResult) async {
        var result = result
        do {
            let montage = try await MontageBuilder().build(result)
            result.montage = montage
        } catch {
            statusMessage = "Montage failed: \(error.localizedDescription)"
        }
        do {
            let strip = try PhotoStripRenderer().render(result, frame: selectedFrameURL)
            result.stripPDF = strip.pdf
            result.stripPNG = strip.png
            result.frameURL = selectedFrameURL
            result.store.saveFrameRef(selectedFrameURL)
        } catch {
            statusMessage = "Photo strip failed: \(error.localizedDescription)"
        }
        lastResult = result
    }

    func dismissResult() {
        lastResult = nil
        coordinator = nil
    }
}
