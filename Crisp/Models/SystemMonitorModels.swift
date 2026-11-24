import Foundation

/// Fixed-capacity circular buffer returning elements in oldest-to-newest order.
struct RingBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private var storage: [Element] = []
    private var head: Int = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    var elements: [Element] {
        if storage.count < capacity || head == 0 {
            return storage
        }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    static func == (lhs: RingBuffer<Element>, rhs: RingBuffer<Element>) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

/// CPU utilization percentages (0...100) and optional package/die temperature in Celsius.
struct CPUSample: Equatable, Sendable {
    let user: Double
    let system: Double
    let idle: Double
    let temperatureC: Double?

    static let zero = CPUSample(user: 0, system: 0, idle: 100, temperatureC: nil)

    init(user: Double, system: Double, idle: Double, temperatureC: Double? = nil) {
        self.user = Self.clampPercent(user)
        self.system = Self.clampPercent(system)
        self.idle = Self.clampPercent(idle)
        if let temp = temperatureC, temp.isFinite {
            self.temperatureC = temp
        } else {
            self.temperatureC = nil
        }
    }

    static func fromTickDeltas(
        user: UInt64,
        nice: UInt64,
        system: UInt64,
        idle: UInt64,
        temperatureC: Double?
    ) -> CPUSample {
        let userTotal = user &+ nice
        let total = userTotal &+ system &+ idle
        guard total > 0 else {
            return CPUSample(user: 0, system: 0, idle: 100, temperatureC: temperatureC)
        }
        let scale = 100.0 / Double(total)
        let userPct = clampPercent(Double(userTotal) * scale)
        let systemPct = clampPercent(Double(system) * scale)
        let idlePct = clampPercent(100.0 - userPct - systemPct)
        return CPUSample(user: userPct, system: systemPct, idle: idlePct, temperatureC: temperatureC)
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}

/// GPU utilization percentages (0...100) from IOAccelerator PerformanceStatistics.
struct GPUSample: Equatable, Sendable {
    let device: Double
    let render: Double
    let tiler: Double

    static let zero = GPUSample(device: 0, render: 0, tiler: 0)

    init(device: Double, render: Double, tiler: Double) {
        self.device = Self.clampPercent(device)
        self.render = Self.clampPercent(render)
        self.tiler = Self.clampPercent(tiler)
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}

/// Snapshot of a single mounted storage volume.
struct VolumeInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mountPath: String
    let fileSystem: String
    let usedBytes: UInt64
    let totalBytes: UInt64
    let isInternal: Bool
    let usedFraction: Double

    /// Remaining available bytes, matching Finder's available capacity semantics.
    var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }

    static func clampedFraction(usedBytes: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

/// Primary disk usage, throughput, temperature, and mounted volume inventory.
struct DiskSnapshot: Equatable, Sendable {
    let name: String
    let usedBytes: UInt64
    let totalBytes: UInt64
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
    let temperatureC: Double?
    let volumes: [VolumeInfo]
    let usedFraction: Double

    /// Remaining available bytes on the primary volume.
    var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }

    func withThroughput(readBytesPerSec: Double, writeBytesPerSec: Double) -> DiskSnapshot {
        DiskSnapshot(
            name: name,
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            readBytesPerSec: readBytesPerSec,
            writeBytesPerSec: writeBytesPerSec,
            temperatureC: temperatureC,
            volumes: volumes,
            usedFraction: usedFraction
        )
    }

    static let empty = DiskSnapshot(
        name: "Macintosh HD",
        usedBytes: 0,
        totalBytes: 0,
        readBytesPerSec: 0,
        writeBytesPerSec: 0,
        temperatureC: nil,
        volumes: [],
        usedFraction: 0
    )
}

/// Raw Mach VM page counts used to construct a `RAMSnapshot`.
struct VMPageCounts: Equatable, Sendable {
    let totalBytes: UInt64
    let pageSize: UInt64
    let activePages: UInt64
    let inactivePages: UInt64
    let speculativePages: UInt64
    let wiredPages: UInt64
    let compressedPages: UInt64
    let purgeablePages: UInt64
    let externalPages: UInt64
    let pressureLevel: Int
}

/// System memory utilization snapshot matching Activity Monitor accounting.
struct RAMSnapshot: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let pressureLevel: Int
    let usedFraction: Double

    static let empty = RAMSnapshot(
        usedBytes: 0,
        totalBytes: 0,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        cachedBytes: 0,
        pressureLevel: 0,
        usedFraction: 0
    )

    /// Computes memory breakdown using Activity Monitor's formula:
    /// `used = active + inactive + speculative + wired + compressed - purgeable - external`.
    static func from(vmCounts: VMPageCounts) -> RAMSnapshot {
        let grossPages = vmCounts.activePages
            .addingReportingOverflow(vmCounts.inactivePages).partialValue
            .addingReportingOverflow(vmCounts.speculativePages).partialValue
            .addingReportingOverflow(vmCounts.wiredPages).partialValue
            .addingReportingOverflow(vmCounts.compressedPages).partialValue
        let deductPages = vmCounts.purgeablePages
            .addingReportingOverflow(vmCounts.externalPages).partialValue
        let usedPages = grossPages > deductPages ? grossPages - deductPages : 0

        let rawUsed = safeMultiply(usedPages, vmCounts.pageSize)
        let usedBytes = vmCounts.totalBytes > 0 ? min(rawUsed, vmCounts.totalBytes) : rawUsed
        let wiredBytes = safeMultiply(vmCounts.wiredPages, vmCounts.pageSize)
        let compressedBytes = safeMultiply(vmCounts.compressedPages, vmCounts.pageSize)
        let cachedBytes = safeMultiply(deductPages, vmCounts.pageSize)
        let nonAppBytes = wiredBytes.addingReportingOverflow(compressedBytes).overflow
            ? UInt64.max
            : wiredBytes + compressedBytes
        let appBytes = usedBytes > nonAppBytes ? usedBytes - nonAppBytes : 0
        let fraction = VolumeInfo.clampedFraction(usedBytes: usedBytes, totalBytes: vmCounts.totalBytes)

        return RAMSnapshot(
            usedBytes: usedBytes,
            totalBytes: vmCounts.totalBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            pressureLevel: vmCounts.pressureLevel,
            usedFraction: fraction
        )
    }

    private static func safeMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

/// Deterministic formatting for storage sizes (decimal SI), RAM sizes (binary GiB as GB), and throughput.
enum ByteRateFormatter {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let decimalKB: Double = 1_000
    private static let decimalMB: Double = 1_000_000
    private static let decimalGB: Double = 1_000_000_000
    private static let decimalTB: Double = 1_000_000_000_000

    private static let binaryKB: Double = 1_024
    private static let binaryMB: Double = 1_048_576
    private static let binaryGB: Double = 1_073_741_824

    /// Formats storage sizes using decimal (base-10) units matching macOS Finder (e.g. `109.21 GB`, `494.38 GB`).
    static func formatDecimalGB(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= decimalTB {
            return String(format: "%.2f TB", locale: posix, value / decimalTB)
        }
        if value >= decimalGB {
            return String(format: "%.2f GB", locale: posix, value / decimalGB)
        }
        if value >= decimalMB {
            return String(format: "%.1f MB", locale: posix, value / decimalMB)
        }
        if value >= decimalKB {
            return String(format: "%.0f KB", locale: posix, value / decimalKB)
        }
        return "\(bytes) B"
    }

    /// Formats memory sizes using binary (base-2) units displayed as GB/MB matching macOS Activity Monitor (e.g. `3.2 GB`, `18.0 GB`).
    static func formatBinaryGB(_ bytes: UInt64) -> String {
        if bytes == 0 {
            return "0.0 GB"
        }
        let value = Double(bytes)
        if value >= binaryGB {
            return String(format: "%.1f GB", locale: posix, value / binaryGB)
        }
        if value >= binaryMB {
            return String(format: "%.0f MB", locale: posix, value / binaryMB)
        }
        if value >= binaryKB {
            return String(format: "%.0f KB", locale: posix, value / binaryKB)
        }
        return "\(bytes) B"
    }

    /// Formats byte transfer rates (e.g. `688 KB/s`, `12.4 MB/s`).
    static func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec > 0 else {
            return "0 B/s"
        }
        if bytesPerSec >= decimalGB {
            return String(format: "%.2f GB/s", locale: posix, bytesPerSec / decimalGB)
        }
        if bytesPerSec >= decimalMB {
            return String(format: "%.1f MB/s", locale: posix, bytesPerSec / decimalMB)
        }
        if bytesPerSec >= decimalKB {
            return String(format: "%.0f KB/s", locale: posix, bytesPerSec / decimalKB)
        }
        return "\(Int(bytesPerSec.rounded())) B/s"
    }
}

/// Pure decoding utilities for AppleSMC four-character codes and temperature sensor encodings.
enum SMCTemperatureCodec {
    static let typeFLT: UInt32 = 0x666C_7420  // 'flt '
    static let typeSP78: UInt32 = 0x7370_3738 // 'sp78'
    static let validTemperatureRange: ClosedRange<Double> = 15.0...115.0

    static func fourCC(from key: String) -> UInt32? {
        let utf8 = Array(key.utf8)
        guard utf8.count == 4 else { return nil }
        return (UInt32(utf8[0]) << 24)
            | (UInt32(utf8[1]) << 16)
            | (UInt32(utf8[2]) << 8)
            | UInt32(utf8[3])
    }

    static func string(fromFourCC code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes.map { Character(UnicodeScalar($0)) })
    }

    static func decode(dataType: UInt32, dataSize: UInt32, bytes: [UInt8]) -> Double? {
        switch dataType {
        case typeFLT:
            guard dataSize == 4, bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case typeSP78:
            guard dataSize == 2, bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        default:
            return nil
        }
    }

    static func isValidTemperature(_ celsius: Double) -> Bool {
        celsius.isFinite && validTemperatureRange.contains(celsius)
    }
}

/// Pairs each reading of a cumulative counter with the one before it, so rates cover only
/// the interval between two consecutive samples. After `reset()` the next reading only
/// re-arms the baseline, so no rate ever spans a period in which sampling was paused.
struct CounterBaseline<Reading: Sendable>: Sendable {
    private var previous: Reading?

    var isArmed: Bool { previous != nil }

    mutating func advance(to current: Reading) -> (previous: Reading, current: Reading)? {
        defer { previous = current }
        guard let previous else { return nil }
        return (previous, current)
    }

    mutating func reset() {
        previous = nil
    }
}
