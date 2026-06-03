import AVFoundation

/// A camera the user can pick. Webcams come from AVFoundation; the Nikon entry
/// appears once the gphoto2 path is wired up (Phase 4).
struct CameraDevice: Identifiable, Hashable {
    enum Kind: Hashable { case webcam, nikon }
    let id: String
    let name: String
    let kind: Kind
}

enum DeviceDiscovery {
    /// All cameras AVFoundation can see: built-in, external USB (UVC), and
    /// Continuity Camera. The Logitech Brio shows up here with no drivers.
    static func webcams() -> [CameraDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, kind: .webcam)
        }
    }

    static func avDevice(for id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }
}
