import SwiftUI

/// Compact control overlay to choose the camera input.
struct SourcePickerView: View {
    @Bindable var controller: CameraController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera")
                .foregroundStyle(.white)
            Picker("Camera", selection: Binding(
                get: { controller.selectedDeviceID ?? "" },
                set: { id in Task { await controller.select(deviceID: id) } }
            )) {
                ForEach(controller.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 200)

            Button {
                controller.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan for cameras")
        }
        .padding(10)
        .background(.black.opacity(0.55), in: Capsule())
    }
}
