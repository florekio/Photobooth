import SwiftUI
import AppKit

/// Main booth screen: full-bleed live preview, countdown/flash overlays, and the
/// Space/Esc hotkeys that drive the capture sequence.
struct BoothView: View {
    @Bindable var controller: CameraController
    @State private var keyMonitor: Any?
    // Transient "current frame" hint shown when the frame changes — the only
    // frame feedback while kiosk-locked (the picker is hidden then).
    @State private var frameHintVisible = false
    @State private var frameHintSeq = 0

    private var phase: CaptureCoordinator.Phase {
        controller.coordinator?.phase ?? .idle
    }

    private var selectedFrameName: String {
        controller.frameOptions.first { $0.id == controller.selectedFrameID }?.name ?? "No frame"
    }

    /// The persistent kiosk frame bar is on the idle screen while locked; the
    /// transient hint pill is redundant then.
    private var kioskFrameBarVisible: Bool {
        controller.isLocked && !controller.isCapturing && controller.lastResult == nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(previewLayer: controller.previewLayer)
                .ignoresSafeArea()

            if controller.previewLayer == nil {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 48))
                    Text(controller.statusMessage ?? "Starting camera…")
                        .font(.title3)
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            overlay

            if let result = controller.lastResult {
                ResultsView(controller: controller, result: result)
                    .transition(.opacity)
            }

            if !controller.isCapturing && controller.lastResult == nil {
                VStack {
                    HStack {
                        Spacer()
                        // Operator control — hidden in kiosk lock.
                        if !controller.isLocked {
                            Button {
                                controller.showingGallery = true
                            } label: {
                                Label("Past sessions", systemImage: "photo.stack")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    // Frame chooser. Operators get the full picker; guests in
                    // kiosk lock get the read-friendly bar with the arrow-key hint.
                    FramePickerView(controller: controller, kiosk: controller.isLocked)
                        .frame(maxWidth: 640)
                        .padding(.bottom, 4)
                    HStack {
                        // Operator control — hidden in kiosk lock.
                        if !controller.isLocked {
                            SourcePickerView(controller: controller)
                        }
                        Spacer()
                        if controller.previewLayer != nil {
                            Text("Press Space to start")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                }
                .padding(24)
            }

            if controller.showingGallery && !controller.isLocked {
                GalleryView { controller.showingGallery = false }
                    .transition(.opacity)
            }

            if controller.showingUnlockPrompt {
                UnlockView(
                    verify: { $0 == controller.kioskPIN },
                    onSuccess: unlock,
                    onCancel: { controller.showingUnlockPrompt = false }
                )
                .transition(.opacity)
            }

            if frameHintVisible && !kioskFrameBarVisible {
                VStack {
                    Spacer()
                    Label("Frame: \(selectedFrameName)", systemImage: "photo.artframe")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .task { await controller.start() }
        .onChange(of: controller.selectedFrameID) {
            // Flash the frame name; keep it up while cycling, hide 1.6s after
            // the last change.
            frameHintSeq += 1
            let seq = frameHintSeq
            withAnimation(.easeOut(duration: 0.15)) { frameHintVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if seq == frameHintSeq {
                    withAnimation(.easeOut(duration: 0.3)) { frameHintVisible = false }
                }
            }
        }
        .onAppear {
            installKeyMonitor()
            // Restore fullscreen if the booth relaunched while locked.
            if controller.isLocked { DispatchQueue.main.async { setFullScreen(true) } }
        }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .countdown(let shot, let remaining):
            CountdownOverlay(number: remaining, shot: shot, total: controller.shotCount, recording: true)
        case .flash:
            Color.white.ignoresSafeArea().transition(.opacity)
        case .recordingAfter(let shot, let remaining):
            RecordingOverlay(remaining: remaining, shot: shot, total: controller.shotCount)
        case .getReady(let next):
            MessageOverlay(title: "Get ready!", subtitle: "Photo \(next) of \(controller.shotCount)")
        case .composing:
            MessageOverlay(title: "Building your photo strip…", subtitle: nil, showsProgress: true)
        case .done:
            MessageOverlay(title: "All done! 🎉", subtitle: "Press Space for another round")
        case .failed(let msg):
            MessageOverlay(title: "Something went wrong", subtitle: msg)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Hotkeys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘L toggles the kiosk lock (hidden from guests) at any time.
            if event.keyCode == 37, event.modifierFlags.contains(.command) {
                toggleLock()
                return nil
            }
            // While the PIN prompt is up, let keystrokes reach the field (so
            // Space doesn't start a capture); Esc cancels the prompt.
            if controller.showingUnlockPrompt {
                if event.keyCode == 53 { controller.showingUnlockPrompt = false; return nil }
                return event
            }
            // Don't drive capture while the gallery is open; let Esc close it.
            if controller.showingGallery {
                if event.keyCode == 53 { controller.showingGallery = false; return nil }
                return event
            }
            // Arrow keys change the strip frame in any state.
            if event.keyCode == 126 { controller.cycleFrame(by: -1); return nil }  // ↑ previous
            if event.keyCode == 125 { controller.cycleFrame(by: +1); return nil }  // ↓ next

            // Results screen: Enter prints, Space starts a new session, Esc closes.
            if controller.lastResult != nil {
                switch event.keyCode {
                case 36: controller.printStrip(); return nil        // Return → print
                case 49: controller.startCapture(); return nil      // Space → new photo
                case 53: controller.dismissResult(); return nil     // Esc → back to idle
                default: return event
                }
            }

            // Idle / capturing.
            switch event.keyCode {
            case 49, 36: // Space, Return
                if !controller.isCapturing { controller.startCapture() }
                return nil
            case 53: // Escape
                controller.cancelCapture()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Kiosk lock

    private func toggleLock() {
        if controller.isLocked {
            // Leaving the booth requires the PIN.
            controller.showingUnlockPrompt = true
        } else {
            controller.isLocked = true
            controller.showingGallery = false
            setFullScreen(true)
        }
    }

    private func unlock() {
        controller.isLocked = false
        controller.showingUnlockPrompt = false
        setFullScreen(false)
    }

    /// Drive native fullscreen to `on`, leaving it alone if already there.
    private func setFullScreen(_ on: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        if window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
        }
    }
}

// MARK: - Kiosk unlock

/// PIN entry to leave kiosk lock. Owns its own text state so the field behaves
/// naturally; `verify` returns true when the entered PIN is correct.
private struct UnlockView: View {
    let verify: (String) -> Bool
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var entry = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("Enter PIN to unlock")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                SecureField("PIN", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit(submit)
                if wrong {
                    Text("Wrong PIN — try again")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack(spacing: 16) {
                    Button("Cancel", action: onCancel)
                    Button("Unlock", action: submit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(40)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
        }
        .onAppear { focused = true }
    }

    private func submit() {
        if verify(entry) {
            onSuccess()
        } else {
            wrong = true
            entry = ""
        }
    }
}

// MARK: - Overlay components

private struct CountdownOverlay: View {
    let number: Int
    let shot: Int
    let total: Int
    let recording: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("\(number)")
                    .font(.system(size: 220, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
                    .contentTransition(.numericText())
                Text("Photo \(shot) of \(total)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if recording { RecordingBadge() }
        }
        .animation(.snappy, value: number)
    }
}

private struct RecordingOverlay: View {
    let remaining: Int
    let shot: Int
    let total: Int

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                Text("Keep going… \(remaining)s")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 80)
            }
            RecordingBadge()
        }
    }
}

private struct RecordingBadge: View {
    var body: some View {
        VStack {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 14, height: 14)
                    Text("REC").font(.headline.weight(.bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                Spacer()
            }
            Spacer()
        }
        .padding(28)
    }
}

private struct MessageOverlay: View {
    let title: String
    var subtitle: String?
    var showsProgress: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                if showsProgress {
                    ProgressView().controlSize(.large).tint(.white)
                }
                Text(title)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
        }
    }
}
