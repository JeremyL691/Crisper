import Foundation
import CoreGraphics

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    /// Moves the given display to the specified position in the global coordinate space.
    /// Used by preset restore, which writes each display's saved absolute origin.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        let targetID: CGDirectDisplayID
        if let virtualSource = MirroredModeService.shared.virtualDisplayID(for: displayID),
           Self.arrangementID(for: displayID) == virtualSource {
            targetID = virtualSource
        } else if CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay {
            targetID = displayID
        } else {
            // A regular mirrored target has no independent position in a preset.
            return true
        }
        PresetService.shared.noteManualChange()
        return await applyOrigins([(targetID, x, y)])
    }

    /// Moves `displayID` to (x, y) for an interactive drag, keeping the main display pinned
    /// at (0, 0): macOS silently renormalizes any config that leaves it off origin, so this
    /// sets every display's origin in one transaction and subtracts the main's proposed
    /// origin from all of them, matching the native Arrange Displays sheet.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID,
                     among displays: [DisplayInfo]) async -> Bool {
        PresetService.shared.noteManualChange()

        // Move a mirror group by its source, even when that source is a hidden HiDPI virtual.
        let sourceID = Self.arrangementID(for: displayID)
        var origins = Self.arrangementIDs(displays).map { id in
            let origin = CGDisplayBounds(id).origin
            return id == sourceID ? (id, x, y) : (id, Int(origin.x), Int(origin.y))
        }
        // Renormalize so the current main sits at (0, 0). When the main is the
        // dragged display, this pushes its offset onto all the others.
        let mainID = Self.arrangementID(for: CGMainDisplayID())
        if let main = origins.first(where: { $0.0 == mainID }), main.1 != 0 || main.2 != 0 {
            origins = origins.map { ($0.0, $0.1 - main.1, $0.2 - main.2) }
        }
        return await applyOrigins(origins)
    }

    /// Makes the target the main display by translating every display by the same vector,
    /// so the relative arrangement is preserved and only the origin moves; swapping just the
    /// target and old-main origins (the previous approach) could overlap a wider display.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID, among displays: [DisplayInfo]) async -> Bool {
        let sourceID = Self.arrangementID(for: targetID)
        let ids = Self.arrangementIDs(displays)
        guard ids.contains(sourceID), sourceID != Self.arrangementID(for: CGMainDisplayID()) else { return false }
        PresetService.shared.noteManualChange()

        let target = CGDisplayBounds(sourceID).origin
        let origins = ids.map { id in
            let origin = CGDisplayBounds(id).origin
            return (id, Int(origin.x) - Int(target.x), Int(origin.y) - Int(target.y))
        }
        return await applyOrigins(origins)
    }

    private static func arrangementID(for id: CGDirectDisplayID) -> CGDirectDisplayID {
        let source = CGDisplayMirrorsDisplay(id)
        return source == kCGNullDirectDisplay ? id : source
    }

    private static func arrangementIDs(_ displays: [DisplayInfo]) -> [CGDirectDisplayID] {
        var seen = Set<CGDirectDisplayID>()
        return displays.map { arrangementID(for: $0.displayID) }.filter { seen.insert($0).inserted }
    }

    /// Applies origins in one atomic transaction inside `CGHelpers.runWithTimeout` so
    /// `CGCompleteDisplayConfiguration` cannot block WindowServer IPC forever. Every caller is
    /// a user action, so it commits `.permanently`: with `.forSession` macOS put its own
    /// stored arrangement back at the next login (#193).
    private func applyOrigins(_ origins: [(id: CGDirectDisplayID, x: Int, y: Int)]) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for o in origins {
                guard CGDisplayMirrorsDisplay(o.id) == kCGNullDirectDisplay,
                      let x = Int32(exactly: o.x), let y = Int32(exactly: o.y),
                      CGConfigureDisplayOrigin(cfg, o.id, x, y) == .success else {
                    CGCancelDisplayConfiguration(cfg)
                    return false
                }
            }
            return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
        }
    }
}
