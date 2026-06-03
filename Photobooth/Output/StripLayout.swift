import CoreGraphics

/// Single source of truth for the photo-strip geometry, shared by the printable
/// renderer, the digital (video) strip, and the frame-template generator.
///
/// Design space is 600×1800 (a classic 2×6" strip, 1:3 portrait). Frame PNGs
/// should match this ratio — ideal size 1200×3600 px (2×6" @ 600 DPI) with
/// transparent windows over each photo cell.
///
/// Coordinates here use a TOP-LEFT origin (y grows downward, like SwiftUI). The
/// Core Graphics renderer flips to bottom-left as needed.
enum StripLayout {
    static let count = 4
    static let designSize = CGSize(width: 600, height: 1800)
    static let margin: CGFloat = 30
    static let gap: CGFloat = 16
    static let footerHeight: CGFloat = 120
    static let cornerRadius: CGFloat = 18

    static var cellSize: CGSize {
        let w = designSize.width - margin * 2
        let totalGaps = gap * CGFloat(count - 1)
        let h = (designSize.height - margin * 2 - footerHeight - totalGaps) / CGFloat(count)
        return CGSize(width: w, height: h)
    }

    /// Cell width / height — photos and video cells aspect-fill this.
    static var cellAspect: CGFloat { cellSize.width / cellSize.height }
    /// Whole-strip width / height (1:3).
    static var stripAspect: CGFloat { designSize.width / designSize.height }

    /// Cell rect in design coordinates (top-left origin).
    static func cellRect(_ index: Int) -> CGRect {
        let y = margin + CGFloat(index) * (cellSize.height + gap)
        return CGRect(x: margin, y: y, width: cellSize.width, height: cellSize.height)
    }

    /// Footer band in design coordinates (top-left origin).
    static var footerRect: CGRect {
        CGRect(x: 0, y: designSize.height - footerHeight,
               width: designSize.width, height: footerHeight)
    }

    /// Cell rect normalized to 0–1 (top-left origin) — for SwiftUI placement.
    static func normalizedCellRect(_ index: Int) -> CGRect {
        let r = cellRect(index)
        return CGRect(x: r.minX / designSize.width, y: r.minY / designSize.height,
                      width: r.width / designSize.width, height: r.height / designSize.height)
    }
}
