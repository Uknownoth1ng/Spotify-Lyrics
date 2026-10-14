import CoreGraphics

enum LyricsPanelAnchorNotificationKey {
    static let anchorFrame = "anchorFrame"
    static let screenNumber = "screenNumber"
}

enum FloatingPanelPreferredEdge {
    case automatic
    case below
    case above
}

struct FloatingPanelPlacement {
    static func origin(
        anchorFrame: CGRect,
        panelSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        preferredEdge: FloatingPanelPreferredEdge = .automatic,
        gap: CGFloat = 0,
        margin: CGFloat = 10
    ) -> CGPoint {
        let x = clamp(
            anchorFrame.midX - panelSize.width / 2,
            lower: visibleFrame.minX + margin,
            upper: visibleFrame.maxX - panelSize.width - margin
        )

        let belowY = anchorFrame.minY - panelSize.height - gap
        let aboveY = anchorFrame.maxY + gap
        let fitsBelow = belowY >= visibleFrame.minY + margin
        let fitsAbove = aboveY + panelSize.height <= visibleFrame.maxY

        let shouldUseBelow: Bool
        switch preferredEdge {
        case .below:
            shouldUseBelow = fitsBelow || !fitsAbove
        case .above:
            shouldUseBelow = fitsBelow && !fitsAbove
        case .automatic:
            if fitsBelow && !fitsAbove {
                shouldUseBelow = true
            } else if fitsAbove && !fitsBelow {
                shouldUseBelow = false
            } else {
                shouldUseBelow = anchorFrame.midY >= screenFrame.midY
            }
        }

        let preferredY = shouldUseBelow ? belowY : aboveY
        let lowerY = visibleFrame.minY + margin
        let upperY = visibleFrame.maxY - panelSize.height
        let y: CGFloat
        if shouldUseBelow, fitsBelow {
            y = preferredY
        } else if !shouldUseBelow, fitsAbove {
            y = preferredY
        } else {
            y = clamp(preferredY, lower: lowerY, upper: upperY)
        }
        return CGPoint(x: x, y: y)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}
