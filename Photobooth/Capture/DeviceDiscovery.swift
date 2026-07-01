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

    /// Cameras libgphoto2 can drive over PTP (the Nikon path). Uses
    /// `gp_camera_autodetect`, which enumerates USB without claiming the device,
    /// so it's safe to call even while macOS's ptpcamerad still holds it.
    static func nikonCameras() -> [CameraDevice] {
        NikonSource.configurePluginPaths()
        var list: OpaquePointer?
        guard gp_list_new(&list) == GP_OK, let list else { return [] }
        defer { gp_list_free(list) }

        let ctx = gp_context_new()
        defer { gp_context_unref(ctx) }
        guard gp_camera_autodetect(list, ctx) >= GP_OK else { return [] }

        var devices: [CameraDevice] = []
        for i in 0..<gp_list_count(list) {
            var namePtr: UnsafePointer<CChar>?
            guard gp_list_get_name(list, i, &namePtr) == GP_OK, let namePtr else { continue }
            let model = String(cString: namePtr)
            // One booth = one body; a single stable id keeps selection simple.
            // gp_camera_init auto-selects the sole connected camera.
            devices.append(CameraDevice(id: "nikon-gphoto2", name: model, kind: .nikon))
        }
        return devices
    }
}
