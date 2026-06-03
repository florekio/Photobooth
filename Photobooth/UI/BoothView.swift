import SwiftUI
import AppKit

/// Main booth screen: full-bleed live preview, countdown/flash overlays, and the
/// Space/Esc hotkeys that drive the capture sequence.
struct BoothView: View {
    @Bindable var controller: CameraController
    @State private var keyMonitor: Any?

    private var phase: CaptureCoordinator.Phase {
        controller.coordinator?.phase ?? .idle
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
                    Spacer()
                    HStack {
                        SourcePickerView(controller: controller)
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

            if controller.showingGallery {
                GalleryView { controller.showingGallery = false }
                    .transition(.opacity)
            }
        }
        .task { await controller.start() }
        .onAppear { installKeyMonitor() }
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
            // Don't drive capture while the gallery is open; let Esc close it.
            if controller.showingGallery {
                if event.keyCode == 53 { controller.showingGallery = false; return nil }
                return event
            }
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
