import CoreGraphics
import Foundation

/// Pure decision core for resolving which `CGDirectDisplayID` to pass to
/// `SLSConfigureDisplayEnabled(..., true)` when reconnecting a disabled physical display
/// or recovering a stranded `softReconnect` blink.
///
/// While a display is disabled via `SLSConfigureDisplayEnabled(..., false)`,
/// `CGDisplayCreateUUIDFromDisplayID` commonly returns `nil`, and during a zero-display
/// blackout `SLSGetDisplayList` can collapse to a placeholder that omits disabled IDs.
/// Falling back to the last-known `CGDirectDisplayID` is safe only when that ID is offline,
/// does not belong to another disconnected record, and does not enumerate with a different
/// non-nil CoreGraphics UUID.
enum PhysicalDisplayReconnectPolicy {
    struct EnumeratedDisplay: Equatable, Sendable {
        let id: CGDirectDisplayID
        let cgUUID: String?
    }

    struct PendingSoftReconnect: Codable, Equatable, Sendable {
        let uuid: String
        let displayID: CGDirectDisplayID?
    }

    static func decodePendingSoftReconnects(data: Data?, legacyUUIDs: [String]?) -> [PendingSoftReconnect] {
        if let data, let decoded = try? JSONDecoder().decode([PendingSoftReconnect].self, from: data) {
            return decoded
        }
        return (legacyUUIDs ?? []).map { PendingSoftReconnect(uuid: $0, displayID: nil) }
    }

    static func matchesProductName(_ displayName: String, productName: String) -> Bool {
        displayName == productName || displayName.hasPrefix(productName + " (")
    }

    /// Dual disconnected identical monitors with no serial/location (or legacy records without
    /// hardwareIdentity) mutually exclude each other in peer checks; keep them reconnectable
    /// whenever more matching panels are physically attached than are already online.
    static func hasUnclaimedIdenticalAttachment(
        recordName: String,
        savedIdentity: DDCServiceMatcher.Identity?,
        attached: [(name: String?, identity: DDCServiceMatcher.Identity?)],
        onlinePeers: [(name: String, identity: DDCServiceMatcher.Identity)]
    ) -> Bool {
        if let saved = savedIdentity {
            guard saved.serial == 0 else { return false }
            let matching = attached.compactMap(\.identity).filter {
                $0.vendor == saved.vendor && $0.product == saved.product && $0.serial == 0
            }
            guard !matching.isEmpty,
                  saved.location == nil || matching.contains(where: { $0.location == nil })
            else { return false }
            let onlineSameModel = onlinePeers.filter {
                $0.identity.vendor == saved.vendor && $0.identity.product == saved.product
            }.count
            return matching.count > onlineSameModel
        }
        let matchingNames = Set(attached.compactMap(\.name).filter { matchesProductName(recordName, productName: $0) })
        guard !matchingNames.isEmpty else { return false }
        let attachedCount = attached.filter { $0.name.map(matchingNames.contains) ?? false }.count
        let onlineCount = onlinePeers.filter { peer in
            matchingNames.contains { matchesProductName(peer.name, productName: $0) }
        }.count
        return attachedCount > onlineCount
    }

    static func resolveTargetID(
        recordDisplayID: CGDirectDisplayID,
        recordUUID: String,
        enumerated: [EnumeratedDisplay],
        onlineIDs: Set<CGDirectDisplayID>,
        otherDisconnectedIDs: Set<CGDirectDisplayID>,
        rescuingBlackout: Bool,
        screensAsleep: Bool,
        activeDisplayCount: Int
    ) -> CGDirectDisplayID? {
        if let matched = enumerated.first(where: { $0.cgUUID == recordUUID }) {
            return matched.id
        }
        guard recordDisplayID != kCGNullDirectDisplay,
              !onlineIDs.contains(recordDisplayID),
              !otherDisconnectedIDs.contains(recordDisplayID)
        else { return nil }
        if rescuingBlackout {
            guard !screensAsleep, activeDisplayCount == 0 else { return nil }
        }
        if let entry = enumerated.first(where: { $0.id == recordDisplayID }) {
            return (entry.cgUUID == nil || entry.cgUUID == recordUUID) ? recordDisplayID : nil
        }
        // In the placeholder-display blackout state, SLSGetDisplayList omits still-attached
        // disabled IDs even though SLSConfigureDisplayEnabled still honors recordDisplayID.
        return rescuingBlackout ? recordDisplayID : nil
    }

    static func resolveStrandedSoftReconnectID(
        markedUUID: String,
        savedDisplayID: CGDirectDisplayID?,
        enumerated: [EnumeratedDisplay],
        onlineIDs: Set<CGDirectDisplayID>
    ) -> CGDirectDisplayID? {
        if let matched = enumerated.first(where: { $0.cgUUID == markedUUID }) {
            return matched.id
        }
        guard let savedDisplayID,
              savedDisplayID != kCGNullDirectDisplay,
              !onlineIDs.contains(savedDisplayID),
              let entry = enumerated.first(where: { $0.id == savedDisplayID }),
              entry.cgUUID == nil || entry.cgUUID == markedUUID
        else { return nil }
        return savedDisplayID
    }
}
