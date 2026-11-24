import Darwin
import Foundation
import IOKit
import os.log

/// Thread-safe AppleSMC temperature reader with dynamic one-time key discovery and
/// runtime `IOHIDEventSystemClient` fallback for Apple Silicon and Intel Macs.
nonisolated final class SMCTemperatureReader: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.crisper.app", category: "smc-temp")

    private static let kSMCUserClientIndex: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyFromIndex: UInt8 = 8
    private static let kSMCGetKeyInfo: UInt8 = 9
    private static let maxEnumeratedKeys: UInt32 = 8192

    private struct CachedSensorKey {
        let key: UInt32
        let dataSize: UInt32
        let dataType: UInt32
    }

    private struct KeyBuckets {
        var intelCPU: [CachedSensorKey] = []
        var applePrimaryCPU: [CachedSensorKey] = []
        var appleFallbackCPU: [CachedSensorKey] = []
        var disk: [CachedSensorKey] = []
    }

    private let lock = NSLock()
    private var connection: io_connect_t = IO_OBJECT_NULL
    private var isProbed = false
    private var cachedCPUKeys: [CachedSensorKey] = []
    private var cachedDiskKeys: [CachedSensorKey] = []
    private var hidFallback: HIDTemperatureFallback?

    init() {
        // Lazy discovery: open AppleSMC and probe keys off-main on the first actual read.
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
        }
        hidFallback?.close()
        hidFallback = nil
    }

    func readCPUTemperatureC() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()

        if let avg = readAverageLocked(keys: cachedCPUKeys) {
            return avg
        }
        return ensureHIDFallbackLocked()?.readCPUTemperatureC()
    }

    func readDiskTemperatureC() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()

        if let avg = readAverageLocked(keys: cachedDiskKeys) {
            return avg
        }
        return ensureHIDFallbackLocked()?.readDiskTemperatureC()
    }

    // MARK: - Connection & Discovery (called under lock)

    private func ensureReadyLocked() {
        if connection == IO_OBJECT_NULL {
            openConnectionLocked()
        }
        if !isProbed {
            probeKeysLocked()
        }
    }

    private func openConnectionLocked() {
        guard connection == IO_OBJECT_NULL else { return }
        guard let matching = IOServiceMatching("AppleSMC") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = IO_OBJECT_NULL
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        if kr == kIOReturnSuccess {
            connection = conn
        } else {
            Self.log.debug("AppleSMC IOServiceOpen failed: \(kr)")
        }
    }

    private func probeKeysLocked() {
        isProbed = true
        cachedCPUKeys = []
        cachedDiskKeys = []
        guard connection != IO_OBJECT_NULL else { return }

        var buckets = KeyBuckets()
        if let totalKeys = readKeyCountLocked(), totalKeys > 0 {
            let count = min(totalKeys, Self.maxEnumeratedKeys)
            for idx in 0..<count {
                guard let keyCode = keyCodeAtIndexLocked(idx) else { continue }
                classifyAndProbeKeyLocked(keyCode, into: &buckets)
            }
        } else {
            probeStaticFallbackKeysLocked(into: &buckets)
        }

        cachedCPUKeys = selectCPUKeys(from: buckets)
        cachedDiskKeys = buckets.disk

        Self.log.debug(
            "SMC probe complete: cpuKeys=\(self.cachedCPUKeys.count), diskKeys=\(self.cachedDiskKeys.count)"
        )
    }

    private func selectCPUKeys(from buckets: KeyBuckets) -> [CachedSensorKey] {
        #if arch(arm64)
        if !buckets.applePrimaryCPU.isEmpty { return buckets.applePrimaryCPU }
        if !buckets.appleFallbackCPU.isEmpty { return buckets.appleFallbackCPU }
        return buckets.intelCPU
        #else
        if !buckets.intelCPU.isEmpty { return buckets.intelCPU }
        if !buckets.applePrimaryCPU.isEmpty { return buckets.applePrimaryCPU }
        return buckets.appleFallbackCPU
        #endif
    }

    private func probeStaticFallbackKeysLocked(into buckets: inout KeyBuckets) {
        let candidates = [
            // Intel CPU
            "TC0D", "TC0P", "TC0E", "TC0F", "TC0C", "TC1C", "TC2C", "TC3C", "TCXC",
            // Apple Silicon CPU (M1–M6)
            "Tp01", "Tp02", "Tp04", "Tp05", "Tp09", "Tp0C", "Tp0D", "Tp0T",
            "Te05", "Te0P", "Te0S", "Tf04", "Tf05",
            // SSD / NAND
            "TH0x", "TH0a", "TH0b", "TH0A", "TH0B"
        ]
        for name in candidates {
            guard let keyCode = SMCTemperatureCodec.fourCC(from: name) else { continue }
            classifyAndProbeKeyLocked(keyCode, into: &buckets)
        }
    }

    private func classifyAndProbeKeyLocked(_ keyCode: UInt32, into buckets: inout KeyBuckets) {
        let name = SMCTemperatureCodec.string(fromFourCC: keyCode)
        guard name.hasPrefix("T") else { return }

        let isDisk = Self.isDiskKeyName(name)
        let isIntelCPU = Self.isIntelCPUKeyName(name)
        let isApplePrimary = Self.isApplePrimaryCPUKeyName(name)
        let isAppleFallback = Self.isAppleFallbackCPUKeyName(name)
        guard isDisk || isIntelCPU || isApplePrimary || isAppleFallback else { return }

        guard let info = readKeyInfoLocked(keyCode) else { return }
        guard info.dataType == SMCTemperatureCodec.typeFLT || info.dataType == SMCTemperatureCodec.typeSP78 else {
            return
        }
        guard let value = readSensorValueLocked(info), SMCTemperatureCodec.isValidTemperature(value) else {
            return
        }

        if isDisk {
            buckets.disk.append(info)
        } else if isApplePrimary {
            buckets.applePrimaryCPU.append(info)
        } else if isAppleFallback {
            buckets.appleFallbackCPU.append(info)
        } else if isIntelCPU {
            buckets.intelCPU.append(info)
        }
    }

    private static func isDiskKeyName(_ name: String) -> Bool {
        name == "TH0x" || name == "TH0a" || name == "TH0b" || name == "TH0A" || name == "TH0B"
    }

    private static func isIntelCPUKeyName(_ name: String) -> Bool {
        if name == "TC0D" || name == "TC0P" || name == "TC0E" || name == "TC0F" || name == "TCXC" || name == "TCXc" {
            return true
        }
        return name.hasPrefix("TC") && name.hasSuffix("C")
    }

    private static func isApplePrimaryCPUKeyName(_ name: String) -> Bool {
        name.hasPrefix("Tp0") || name.hasPrefix("Te0")
    }

    private static func isAppleFallbackCPUKeyName(_ name: String) -> Bool {
        name.hasPrefix("Tf0")
    }

    // MARK: - Low-Level AppleSMC Calls (called under lock)

    private func callSMCLocked(_ input: CrispSMCKeyData_t) -> CrispSMCKeyData_t? {
        guard connection != IO_OBJECT_NULL else { return nil }
        var inputCopy = input
        var output = CrispSMCKeyData_t()
        var outputSize = MemoryLayout<CrispSMCKeyData_t>.size

        let kr = IOConnectCallStructMethod(
            connection,
            Self.kSMCUserClientIndex,
            &inputCopy,
            MemoryLayout<CrispSMCKeyData_t>.size,
            &output,
            &outputSize
        )
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func readKeyCountLocked() -> UInt32? {
        guard let countKey = SMCTemperatureCodec.fourCC(from: "#KEY"),
              let info = readKeyInfoLocked(countKey),
              info.dataSize == 4 else {
            return nil
        }
        var input = CrispSMCKeyData_t()
        input.key = countKey
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.kSMCReadKey
        guard let output = callSMCLocked(input) else { return nil }
        let b = extractBytes(from: output, count: 4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private func keyCodeAtIndexLocked(_ index: UInt32) -> UInt32? {
        var input = CrispSMCKeyData_t()
        input.data8 = Self.kSMCGetKeyFromIndex
        input.data32 = index
        return callSMCLocked(input)?.key
    }

    private func readKeyInfoLocked(_ keyCode: UInt32) -> CachedSensorKey? {
        var input = CrispSMCKeyData_t()
        input.key = keyCode
        input.data8 = Self.kSMCGetKeyInfo
        guard let output = callSMCLocked(input) else { return nil }
        return CachedSensorKey(
            key: keyCode,
            dataSize: output.keyInfo.dataSize,
            dataType: output.keyInfo.dataType
        )
    }

    private func readSensorValueLocked(_ sensor: CachedSensorKey) -> Double? {
        var input = CrispSMCKeyData_t()
        input.key = sensor.key
        input.keyInfo.dataSize = sensor.dataSize
        input.data8 = Self.kSMCReadKey
        guard let output = callSMCLocked(input) else { return nil }
        let byteCount = min(Int(sensor.dataSize), 32)
        let bytes = extractBytes(from: output, count: byteCount)
        return SMCTemperatureCodec.decode(
            dataType: sensor.dataType,
            dataSize: sensor.dataSize,
            bytes: bytes
        )
    }

    private func readAverageLocked(keys: [CachedSensorKey]) -> Double? {
        guard !keys.isEmpty, connection != IO_OBJECT_NULL else { return nil }
        var sum = 0.0
        var count = 0
        for key in keys {
            if let value = readSensorValueLocked(key), SMCTemperatureCodec.isValidTemperature(value) {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private func extractBytes(from data: CrispSMCKeyData_t, count: Int) -> [UInt8] {
        var copy = data.bytes
        return withUnsafeBytes(of: &copy) { raw in
            Array(raw.prefix(count))
        }
    }

    private func ensureHIDFallbackLocked() -> HIDTemperatureFallback? {
        if hidFallback == nil {
            hidFallback = HIDTemperatureFallback()
        }
        return hidFallback
    }
}

// MARK: - Runtime IOHIDEventSystemClient Fallback

private final class HIDTemperatureFallback {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, UInt32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: UInt32 = 15 << 16

    private var handle: UnsafeMutableRawPointer?
    private var client: CFTypeRef?
    private var copyServicesFn: CopyServicesFn?
    private var copyPropertyFn: CopyPropertyFn?
    private var copyEventFn: CopyEventFn?
    private var getFloatFn: GetFloatFn?
    private var isServicesCached = false
    private var cachedCPUServices: [CFTypeRef] = []
    private var cachedDiskServices: [CFTypeRef] = []

    init() {
        guard let dl = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return
        }
        handle = dl
        guard let createSym = dlsym(dl, "IOHIDEventSystemClientCreate"),
              let setMatchSym = dlsym(dl, "IOHIDEventSystemClientSetMatching"),
              let copySvcSym = dlsym(dl, "IOHIDEventSystemClientCopyServices"),
              let copyPropSym = dlsym(dl, "IOHIDServiceClientCopyProperty"),
              let copyEvtSym = dlsym(dl, "IOHIDServiceClientCopyEvent"),
              let getFloatSym = dlsym(dl, "IOHIDEventGetFloatValue") else {
            close()
            return
        }

        let createFn = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatchingFn = unsafeBitCast(setMatchSym, to: SetMatchingFn.self)
        copyServicesFn = unsafeBitCast(copySvcSym, to: CopyServicesFn.self)
        copyPropertyFn = unsafeBitCast(copyPropSym, to: CopyPropertyFn.self)
        copyEventFn = unsafeBitCast(copyEvtSym, to: CopyEventFn.self)
        getFloatFn = unsafeBitCast(getFloatSym, to: GetFloatFn.self)

        guard let created = createFn(kCFAllocatorDefault)?.takeRetainedValue() else {
            close()
            return
        }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        setMatchingFn(created, matching as CFDictionary)
        client = created
    }

    deinit {
        close()
    }

    func close() {
        cachedCPUServices.removeAll()
        cachedDiskServices.removeAll()
        isServicesCached = false
        client = nil
        copyServicesFn = nil
        copyPropertyFn = nil
        copyEventFn = nil
        getFloatFn = nil
        if let dl = handle {
            dlclose(dl)
            handle = nil
        }
    }

    func readCPUTemperatureC() -> Double? {
        ensureServicesCached()
        return readAverage(from: cachedCPUServices)
    }

    func readDiskTemperatureC() -> Double? {
        ensureServicesCached()
        return readAverage(from: cachedDiskServices)
    }

    private func ensureServicesCached() {
        guard !isServicesCached else { return }
        isServicesCached = true
        guard let client,
              let copyServicesFn,
              let copyPropertyFn,
              let servicesRef = copyServicesFn(client)?.takeRetainedValue() else {
            return
        }
        let count = CFArrayGetCount(servicesRef)
        guard count > 0 else { return }

        let productKey = "Product" as CFString
        for idx in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(servicesRef, idx) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(rawPtr).takeUnretainedValue()
            guard let propRef = copyPropertyFn(service, productKey)?.takeRetainedValue(),
                  let name = propRef as? String else {
                continue
            }
            if name.hasPrefix("PMU tdie") || name.contains("pACC MTR") || name.contains("eACC MTR") {
                cachedCPUServices.append(service)
            } else {
                let lower = name.lowercased()
                if lower.contains("nand ch") && lower.contains("temp") {
                    cachedDiskServices.append(service)
                }
            }
        }
    }

    private func readAverage(from services: [CFTypeRef]) -> Double? {
        guard !services.isEmpty, let copyEventFn, let getFloatFn else { return nil }
        var sum = 0.0
        var matched = 0

        for service in services {
            guard let eventRef = copyEventFn(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let temp = getFloatFn(eventRef, Self.temperatureField)
            if SMCTemperatureCodec.isValidTemperature(temp) {
                sum += temp
                matched += 1
            }
        }
        return matched > 0 ? sum / Double(matched) : nil
    }
}
