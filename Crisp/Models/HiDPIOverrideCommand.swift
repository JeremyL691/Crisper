import Foundation
import CryptoKit

/// Builds the one-shot authorized install without a user-writable source pathname.
/// Only numeric display identifiers and Base64-encoded, validated plist bytes enter the shell.
enum HiDPIOverrideCommand {
    private static let modesKey = "scale-resolutions"
    private static let ownershipKey = "com.crisper.added-scale-resolutions"

    private struct Ownership: Codable {
        let modes: [Data]
        let hadModes: Bool
        let hadFile: Bool
    }

    static func install(vendor: UInt32, product: UInt32, scaledModes: [Data], previous: Data? = nil) throws -> String {
        guard !scaledModes.isEmpty, scaledModes.count <= 4_096,
              scaledModes.allSatisfy({ $0.count == 8 }) else { throw InvalidModes() }
        var plist = try previous.map(dictionary) ?? [:]
        let ownership = try stripOwnedModes(from: &plist)
        let hadModes = plist[modesKey] != nil
        let existing = try modes(in: plist)
        var seen = Set(existing)
        let added = scaledModes.filter { seen.insert($0).inserted }
        if !added.isEmpty {
            plist[modesKey] = existing + added
            plist[ownershipKey] = try PropertyListEncoder().encode(
                Ownership(modes: added, hadModes: hadModes, hadFile: ownership?.hadFile ?? (previous != nil))
            )
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try update(vendor: vendor, product: product, previous: previous, replacement: data)
    }

    static func uninstall(vendor: UInt32, product: UInt32, previous: Data) throws -> String {
        var plist = try dictionary(previous)
        guard let ownership = try stripOwnedModes(from: &plist) else { throw InvalidOverride.unmanaged }
        let replacement = ownership.hadFile || !plist.isEmpty
            ? try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            : nil
        return try update(vendor: vendor, product: product, previous: previous, replacement: replacement)
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw InvalidOverride.malformed }
        return plist
    }

    private static func modes(in plist: [String: Any]) throws -> [Data] {
        guard let value = plist[modesKey] else { return [] }
        guard let modes = value as? [Data] else { throw InvalidOverride.malformed }
        return modes
    }

    private static func stripOwnedModes(from plist: inout [String: Any]) throws -> Ownership? {
        guard let metadata = plist.removeValue(forKey: ownershipKey) else { return nil }
        guard let data = metadata as? Data else { throw InvalidOverride.malformed }
        let ownership = try PropertyListDecoder().decode(Ownership.self, from: data)
        let added = Set(ownership.modes)
        let remaining = try modes(in: plist).filter { !added.contains($0) }
        if remaining.isEmpty, !ownership.hadModes {
            plist.removeValue(forKey: modesKey)
        } else {
            plist[modesKey] = remaining
        }
        return ownership
    }

    private static func update(vendor: UInt32, product: UInt32, previous: Data?, replacement: Data?) throws -> String {
        // Leave ample headroom for Base64 and the shell template below macOS's argument limit.
        guard (replacement?.count ?? 0) <= 96 * 1_024 else { throw InvalidModes() }
        let directory = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(String(vendor, radix: 16))"
        let destination = "\(directory)/DisplayProductID-\(String(product, radix: 16))"
        let check: String
        if let previous {
            let digest = SHA256.hash(data: previous).map { String(format: "%02x", $0) }.joined()
            check = """
            [ -f '\(destination)' ] &&
            /usr/bin/shasum -a 256 < '\(destination)' | /usr/bin/grep -q '^\(digest) '
            """
        } else {
            check = "[ ! -e '\(destination)' ]"
        }
        let guardDestination = """
        if ! { [ ! -L '\(destination)' ] && \(check); }; then
            echo 'The display override changed. Try again.' >&2
            exit 1
        fi
        """
        guard let data = replacement else {
            return "set -eu\n\(guardDestination)\n/bin/rm -f '\(destination)'"
        }
        return """
        set -eu
        /bin/mkdir -p '\(directory)'
        [ ! -L '\(directory)' ]
        stage=$(/usr/bin/mktemp '\(directory)/.crisp-override.XXXXXXXX')
        trap '/bin/rm -f "$stage"' EXIT
        /usr/bin/printf '%s' '\(data.base64EncodedString())' | /usr/bin/base64 -D > "$stage"
        /usr/bin/plutil -lint -s "$stage"
        /bin/chmod 644 "$stage"
        \(guardDestination)
        /bin/mv -fh "$stage" '\(destination)'
        """
    }

    /// The existing authorization helper expects an already escaped AppleScript literal.
    static func appleScriptLiteral(_ command: String) -> String {
        command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private struct InvalidModes: LocalizedError {
        var errorDescription: String? { "Invalid HiDPI scale resolutions" }
    }

    private enum InvalidOverride: LocalizedError {
        case malformed, unmanaged

        var errorDescription: String? {
            switch self {
            case .malformed: return String(localized: "The existing display override could not be read safely.")
            case .unmanaged: return String(localized: "The existing display override is not managed by Crisper.")
            }
        }
    }
}
