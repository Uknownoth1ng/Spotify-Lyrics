import AppKit
import Combine

/// Detects whether the Mac has a built-in display with a notch (camera housing).
/// macOS doesn't expose a "hasNotch" API, but we can infer it: if the built-in
/// screen's `frame.height` minus `visibleFrame.height + visibleFrame.origin.y`
/// leaves a top inset > 24pt (the standard menu bar is ~24pt; notch models have
/// ~38pt), the display has a notch.
///
/// This is a heuristic — it works on all MacBook Pro 14"/16" (2021+) and
/// MacBook Air 15" (2023+) models. Non-notch MacBooks and external displays
/// return false.
enum NotchDisplayDetector {
    /// Returns the built-in screen if it has a notch, or nil.
    static var builtInNotchScreen: NSScreen? {
        guard let builtIn = builtInScreen else { return nil }
        return hasNotch(builtIn) ? builtIn : nil
    }

    /// Quick check: does any connected display have a notch?
    static var hasBuiltInNotchDisplay: Bool {
        builtInNotchScreen != nil
    }

    /// Returns the built-in display (laptop screen), or nil if only external
    /// monitors are connected (e.g. clamshell mode).
    static var builtInScreen: NSScreen? {
        // The built-in display always has displayID matching
        // CGMainDisplayID() when it's the only screen, but in multi-monitor
        // setups we need to check the display's connection type.
        // CGDisplayIsBuiltin is the reliable check.
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(displayID) != 0 {
                return screen
            }
        }
        return nil
    }

    /// Heuristic: notch displays have a top safe-area inset of ~38pt (the notch
    /// housing extends below the top of the frame into the menu bar area). Standard
    /// menu-bar-only displays have ~24pt.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            let topInset = screen.safeAreaInsets.top
            return topInset > 0
        }
        // Fallback for macOS 11 (shouldn't happen since we target 14+, but safe).
        let frame = screen.frame
        let visible = screen.visibleFrame
        let topGap = frame.maxY - visible.maxY
        return topGap > 30
    }

    /// The Y coordinate (in screen coords) where the capsule should sit — just
    /// below the menu bar, clear of the notch camera area.
    static func capsuleY(on screen: NSScreen) -> CGFloat {
        // visibleFrame.maxY is the bottom of the menu bar. We want the capsule's
        // top edge to be flush with the bottom of the menu bar (or 2pt below for
        // breathing room).
        screen.visibleFrame.maxY - 2
    }

    /// Center X for the capsule on the given screen.
    static func capsuleCenterX(on screen: NSScreen) -> CGFloat {
        screen.frame.midX
    }
}
