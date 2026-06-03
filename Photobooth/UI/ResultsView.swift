import SwiftUI
import AVKit

/// Shown after a session: plays the stitched montage, previews the printable
/// strip, and offers reveal/print actions.
struct ResultsView: View {
    @Bindable var controller: CameraController
    let result: SessionResult

    private let stripHeight: CGFloat = 540

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Your photobooth strip")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)

                HStack(alignment: .top, spacing: 40) {
                    digitalPanel
                    stripPanel
                }

                actions
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private var digitalPanel: some View {
        VStack(spacing: 8) {
            Text("Digital strip (video)").font(.headline).foregroundStyle(.white.opacity(0.8))
            DigitalStripView(result: result, height: stripHeight)
        }
    }

    @ViewBuilder
    private var stripPanel: some View {
        VStack(spacing: 8) {
            Text("Printable strip").font(.headline).foregroundStyle(.white.opacity(0.8))
            Group {
                if let png = result.stripPNG, let img = NSImage(contentsOf: png) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    placeholder("Strip unavailable")
                        .frame(width: 220, height: stripHeight)
                }
            }
            .frame(height: stripHeight)
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
            Text(text).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([result.store.root])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if let pdf = result.stripPDF {
                Button {
                    NSWorkspace.shared.open(pdf)
                } label: {
                    Label("Open strip PDF", systemImage: "printer")
                }
            }

            Button {
                controller.dismissResult()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }
}
