import AppKit

/// Where the notch is, or where it would be on a screen that doesn't have one.
struct NotchMetrics: Equatable {
    let screenFrame: CGRect
    /// Screen coordinates of the notch cutout itself.
    let notch: CGRect

    var centerX: CGFloat { notch.midX }
    var topY: CGFloat { screenFrame.maxY }
    var width: CGFloat { notch.width }
    var height: CGFloat { notch.height }

    static func current(preferring screen: NSScreen? = nil) -> NotchMetrics? {
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return nil }
        let frame = screen.frame

        // On a notched Mac the two "auxiliary" areas are the usable strips either
        // side of the cutout, so the gap between them is the notch.
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            let notch = CGRect(
                x: left.maxX,
                y: frame.maxY - screen.safeAreaInsets.top,
                width: right.minX - left.maxX,
                height: screen.safeAreaInsets.top
            )
            return NotchMetrics(screenFrame: frame, notch: notch)
        }

        // No notch: pretend there is one the size of the menu bar, centred.
        let height = max(24, NSStatusBar.system.thickness)
        let width: CGFloat = 190
        let notch = CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
        return NotchMetrics(screenFrame: frame, notch: notch)
    }
}
