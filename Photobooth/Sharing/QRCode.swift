import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Local, offline QR-code generation via CoreImage — no network, no cost.
enum QRCode {
    /// Render `string` as a crisp (nearest-neighbour scaled) QR `NSImage`.
    static func image(from string: String, scale: CGFloat = 14) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
