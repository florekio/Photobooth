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

    /// Embedded HTTP server + Cloudflare quick tunnel that make each session
    /// shareable via a QR code.
    let share = ShareService()

    private(set) var coordinator: CaptureCoordinator?
    /// Most recent finished session, shown by ResultsView (Phase 3).
    var lastResult: SessionResult?

    var statusMessage: String?
    var showingGallery = false

    /// Kiosk lock: hides all operator controls (camera picker, gallery) and puts
    /// the window fullscreen so guests can only start a session. Toggled with ⌘L.
    /// Persisted so the booth comes back locked after a relaunch.
    var isLocked = UserDefaults.standard.bool(forKey: "kioskLocked") {
        didSet { UserDefaults.standard.set(isLocked, forKey: "kioskLocked") }
    }
    /// Whether the PIN entry overlay is up (⌘L while locked asks for the PIN).
    var showingUnlockPrompt = false
    /// PIN required to leave kiosk lock. Defaults to 1337; overridable via the
    /// `kioskPIN` user default.
    var kioskPIN: String = UserDefaults.standard.string(forKey: "kioskPIN") ?? "1337" {
        didSet { UserDefaults.standard.set(kioskPIN, forKey: "kioskPIN") }
    }

    // Frames
    private(set) var frameOptions: [FrameOption] = [FrameOption(id: "none", name: "No frame", url: nil)]
    var selectedFrameID: String = "none"
    var selectedFrameURL: URL? { frameOptions.first(where: { $0.id == selectedFrameID })?.url }

    var isCapturing: Bool { coordinator?.isRunning ?? false }
    var shotCount: Int { coordinator?.config.shots ?? 4 }

    /// Discover bundled frame PNGs (any file named `frame…`, case-insensitive —
    /// e.g. `frame-green.png`, `Frame_1.png`) plus the built-in "No frame".
    func loadFrames() {
        var options: [FrameOption] = [FrameOption(id: "none", name: "No frame", url: nil)]
        let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where url.lastPathComponent.lowercased().hasPrefix("frame") {
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
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

    /// Step through the available frames (arrow keys, usable in kiosk lock).
    /// Wraps around; `delta` -1 = previous, +1 = next.
    func cycleFrame(by delta: Int) {
        guard !frameOptions.isEmpty else { return }
        let count = frameOptions.count
        let current = frameOptions.firstIndex { $0.id == selectedFrameID } ?? 0
        let next = ((current + delta) % count + count) % count
        selectFrame(frameOptions[next].id)
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
            result.stripJPG = strip.jpg
            result.frameURL = selectedFrameURL
            result.store.saveFrameRef(selectedFrameURL)
            lastResult = result
        } catch {
            statusMessage = "Photo strip failed: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        var found = DeviceDiscovery.webcams()
        // Real Nikon bodies detected over PTP; only listed when actually connected.
        found.append(contentsOf: DeviceDiscovery.nikonCameras())
        devices = found
        if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = found.first(where: { $0.kind == .webcam })?.id ?? found.first?.id
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
        share.startIfNeeded()
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
            result.stripJPG = strip.jpg
            result.frameURL = selectedFrameURL
            result.store.saveFrameRef(selectedFrameURL)
        } catch {
            statusMessage = "Photo strip failed: \(error.localizedDescription)"
        }
        do {
            result.stripGIF = try await StripGifBuilder().build(result, frame: selectedFrameURL)
        } catch {
            statusMessage = "Strip GIF failed: \(error.localizedDescription)"
        }
        lastResult = result
    }

    func dismissResult() {
        lastResult = nil
        coordinator = nil
    }

    /// Print the current result's strip as a 4×6" double-strip sheet on the
    /// SELPHY. In kiosk lock it prints silently (no panel) so guests just tap.
    func printStrip() {
        guard let png = lastResult?.stripPNG else {
            statusMessage = "Nothing to print yet."
            return
        }
        do {
            try StripPrinter.printDoubleStrip(stripPNG: png, showPanel: !isLocked)
        } catch {
            statusMessage = "Print failed: \(error.localizedDescription)"
        }
    }
}
