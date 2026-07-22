import SwiftUI

/// Shown after a session. Guest-facing and intentionally minimal: a big QR code
/// that opens a mobile page to watch, download, and share the photo + video.
/// The operator keeps a couple of small utility actions at the bottom.
struct ResultsView: View {
    @Bindable var controller: CameraController
    let result: SessionResult

    private var shareURL: URL? { controller.share.shareURL(for: result.store) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 22) {
                Text("Scanne für deine Fotos & Videos")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                content

                operatorActions
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.share.state {
        case .ready where shareURL != nil:
            qrPanel(for: shareURL!)
        case .unavailable(let message):
            unavailable(message)
        default:
            preparing
        }
    }

    // MARK: - QR

    private let stripHeight: CGFloat = 380

    private func qrPanel(for url: URL) -> some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(spacing: 8) {
                Text("Video-Streifen")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                DigitalStripView(result: result,
                                 frameURL: controller.selectedFrameURL,
                                 height: stripHeight)
                    .shadow(radius: 14)
            }

            VStack(spacing: 8) {
                Text("Fotostreifen")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                photoStrip
            }

            VStack(spacing: 14) {
                if let qr = QRCode.image(from: url.absoluteString) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    placeholder("QR nicht verfügbar", width: 200, height: 200)
                }

                Text("Richte deine Handy-Kamera auf den Code")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))

                Text(url.host ?? url.absoluteString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    /// Same fixed box as the video strip so it can't be squeezed to zero width
    /// inside the HStack.
    private var stripWidth: CGFloat { stripHeight * StripLayout.stripAspect }

    @ViewBuilder
    private var photoStrip: some View {
        if let png = result.stripPNG, let img = NSImage(contentsOf: png) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: stripWidth, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 14)
        } else {
            placeholder("Streifen nicht verfügbar", width: stripWidth, height: stripHeight)
        }
    }

    // MARK: - Transient states

    private var preparing: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(.white)
            Text("Link wird vorbereitet…")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 360, height: 360)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Teilen nicht verfügbar")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Deine Fotos sind auf diesem Mac gespeichert.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(minHeight: 360)
    }

    private func placeholder(_ text: String, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.08))
            Text(text).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: width, height: height)
    }

    // MARK: - Operator actions

    private var operatorActions: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                // Prints two strips on one 4×6" sheet. Available to guests even in
                // kiosk lock, where it prints silently straight to the SELPHY.
                Button {
                    controller.printStrip()
                } label: {
                    Label("Drucken", systemImage: "printer")
                }

                Button {
                    controller.startCapture()
                } label: {
                    Label("Neue Fotos", systemImage: "camera")
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            keyHints
        }
    }

    /// Spells out the hotkeys so guests know what to press — large and readable
    /// from a step back.
    private var keyHints: some View {
        HStack(spacing: 28) {
            hint("return", "Drucken")
            hint("space", "Neue Fotos")
            hint("arrow.up.arrow.down", "Rahmen wechseln")
        }
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    private func hint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(minWidth: 44, minHeight: 36)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            Text(label)
        }
    }
}
