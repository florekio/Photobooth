import SwiftUI

/// Horizontal frame chooser: "No frame", each bundled/custom frame as a swatch,
/// plus a button to load any PNG from disk.
struct FramePickerView: View {
    @Bindable var controller: CameraController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.artframe").foregroundStyle(.white.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(controller.frameOptions) { option in
                        swatch(option)
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                controller.chooseCustomFrame()
            } label: {
                Label("Choose PNG…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    @ViewBuilder
    private func swatch(_ option: FrameOption) -> some View {
        let selected = controller.selectedFrameID == option.id
        Button {
            controller.selectFrame(option.id)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12))
                    if let url = option.url, let img = NSImage(contentsOf: url) {
                        Image(nsImage: img).resizable().scaledToFit().padding(2)
                    } else {
                        Image(systemName: "nosign").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 26, height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.accentColor : .white.opacity(0.25),
                                lineWidth: selected ? 2.5 : 1)
                )
                Text(option.name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
