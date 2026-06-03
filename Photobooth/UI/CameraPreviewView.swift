import SwiftUI
import AVFoundation

/// Hosts the capture source's preview `CALayer`, resizing it to fill the view.
struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: CALayer?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.attach(previewLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.attach(previewLayer)
    }

    final class PreviewNSView: NSView {
        private var hosted: CALayer?

        func attach(_ layer: CALayer?) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            hosted = layer
            if let layer, let host = self.layer {
                layer.frame = host.bounds
                host.addSublayer(layer)
            }
            layoutHosted()
        }

        override func layout() {
            super.layout()
            layoutHosted()
        }

        private func layoutHosted() {
            guard let host = layer, let hosted else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = host.bounds
            CATransaction.commit()
        }
    }
}
