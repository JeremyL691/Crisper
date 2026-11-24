import AppKit
import Combine
import Darwin
import Foundation
import IOKit
import os.log

/// Adaptive hardware telemetry service providing CPU, GPU, Disk, RAM, and thermal readings.
/// Polls at 0 Hz when panel is hidden and menu bar temperature is disabled.
@MainActor
final class SystemMonitorService: ObservableObject {
    static let shared = SystemMonitorService()

    private static let log = Logger(subsystem: "com.crisper.app", category: "system-monitor")
    private static let historyCapacity = 32

    let cpuModelName: String
    let gpuModelName: String
    let gpuCoreCount: Int

    @Published private(set) var cpuSample: CPUSample = .zero
    @Published private(set) var cpuHistory: [CPUSample] = []
    @Published private(set) var cpuTemperatureC: Double? = nil
    @Published private(set) var gpuSample: GPUSample = .zero
    @Published private(set) var gpuHistory: [GPUSample] = []
    @Published private(set) var disk: DiskSnapshot = .empty
    @Published private(set) var ram: RAMSnapshot = .empty
    @Published private(set) var isFreeingMemory: Bool = false
    @Published private(set) var freeMemoryFeedback: String? = nil

    private let collector: TelemetryCollector
    private var cpuRing = RingBuffer<CPUSample>(capacity: SystemMonitorService.historyCapacity)
    private var gpuRing = RingBuffer<GPUSample>(capacity: SystemMonitorService.historyCapacity)

    private var isStarted = false
    private var isShutdown = false
    private var isPanelVisible = false
    private var isMenuBarTempEnabled = false
    private var isSleeping = false
    private var areScreensAsleep = false
    private var consecutiveNilTempReads = 0

    private var pollTask: Task<Void, Never>?
    /// CPU ticks and disk byte counters are cumulative. Any pause in full polling would turn
    /// the next delta into an average over the whole time the panel was closed or the Mac was
    /// asleep, so the next full sample re-arms the baselines instead of reporting a rate.
    private var rateBaselinesNeedReset = true
    private var feedbackClearTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        let cpuName = TelemetryHardwareInfo.readCPUModelName()
        let gpuInfo = TelemetryHardwareInfo.readGPUInfo(fallbackModel: cpuName)
        self.cpuModelName = cpuName
        self.gpuModelName = gpuInfo.modelName
        self.gpuCoreCount = gpuInfo.coreCount
        self.collector = TelemetryCollector(
            totalRAMBytes: TelemetryHardwareInfo.readTotalRAMBytes()
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isShutdown = false

        let settings = SettingsService.shared
        isMenuBarTempEnabled = settings.menuBarDisplayMode != .iconOnly

        settings.$monitorRefreshInterval
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reschedulePolling(immediate: false)
            }
            .store(in: &cancellables)

        settings.$menuBarTempRefreshInterval
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reschedulePolling(immediate: false)
            }
            .store(in: &cancellables)

        settings.$showSystemMonitor
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.reschedulePolling(immediate: self.isPanelVisible)
            }
            .store(in: &cancellables)

        registerWorkspaceObservers()
        reschedulePolling(immediate: true)
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        reschedulePolling(immediate: visible)
    }

    func setMenuBarTempEnabled(_ enabled: Bool) {
        guard isMenuBarTempEnabled != enabled else { return }
        isMenuBarTempEnabled = enabled
        reschedulePolling(immediate: enabled && !isPanelVisible)
    }

    func refreshDiskVolumes() {
        guard !isShutdown else { return }
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.collector.sampleDiskCapacity(includeVolumes: true)
            guard !self.isShutdown else { return }
            self.disk = snapshot.withThroughput(
                readBytesPerSec: self.disk.readBytesPerSec,
                writeBytesPerSec: self.disk.writeBytesPerSec
            )
        }
    }

    func freeUpMemory() {
        guard !isFreeingMemory, !isShutdown else { return }
        isFreeingMemory = true
        freeMemoryFeedback = nil
        feedbackClearTask?.cancel()
        let beforeUsed = ram.usedBytes

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFreeingMemory = false }

            let result = await PrivilegedHelperService.shared.execute(.purgeMemory, promptIfNeeded: true)
            guard !self.isShutdown else { return }

            switch result {
            case .success:
                let updatedRAM = await self.collector.sampleRAM()
                guard !self.isShutdown else { return }
                self.ram = updatedRAM
                if beforeUsed > updatedRAM.usedBytes {
                    let freed = beforeUsed - updatedRAM.usedBytes
                    self.setTemporaryFeedback("-\(ByteRateFormatter.formatBinaryGB(freed))")
                } else {
                    self.setTemporaryFeedback(String(localized: "Done"))
                }
            case .failure(let error):
                self.setTemporaryFeedback(error.localizedDescription)
            }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        pollTask?.cancel()
        pollTask = nil
        feedbackClearTask?.cancel()
        feedbackClearTask = nil
        cancellables.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let collector = self.collector
        Task.detached(priority: .utility) {
            await collector.close()
        }
    }

    // MARK: - Adaptive Scheduling

    private enum PollMode: Equatable {
        case stopped
        case temperatureOnly(interval: TimeInterval)
        case full(interval: TimeInterval)

        var isFull: Bool {
            if case .full = self { return true }
            return false
        }
    }

    /// After a rate baseline is re-armed, the first real CPU/disk rate follows this soon
    /// instead of a full refresh interval later.
    private static let rateWarmupSeconds: TimeInterval = 1.0

    private var desiredPollMode: PollMode {
        guard isStarted, !isShutdown, !isSleeping, !areScreensAsleep else { return .stopped }
        let settings = SettingsService.shared
        if isPanelVisible && settings.showSystemMonitor {
            return .full(interval: max(0.5, settings.monitorRefreshInterval))
        }
        if isMenuBarTempEnabled {
            return .temperatureOnly(interval: max(1.0, settings.menuBarTempRefreshInterval))
        }
        return .stopped
    }

    private func reschedulePolling(immediate: Bool) {
        pollTask?.cancel()
        pollTask = nil

        let mode = desiredPollMode
        if !mode.isFull { rateBaselinesNeedReset = true }
        guard mode != .stopped else { return }

        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var tickCount = 0
            if !immediate {
                let delay = Self.intervalSeconds(for: mode)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            while !Task.isCancelled, !self.isShutdown {
                switch mode {
                case .stopped:
                    return
                case .temperatureOnly(let interval):
                    let temp = await self.collector.sampleTemperatureOnly()
                    guard !Task.isCancelled, !self.isShutdown else { return }
                    self.updateCPUTemperature(temp)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                case .full(let interval):
                    let refreshVolumes = (tickCount % 5 == 0)
                    tickCount += 1
                    let resetRateBaselines = self.rateBaselinesNeedReset
                    self.rateBaselinesNeedReset = false
                    let payload = await self.collector.sampleFull(
                        includeVolumes: refreshVolumes,
                        resetRateBaselines: resetRateBaselines
                    )
                    guard !Task.isCancelled, !self.isShutdown else { return }
                    self.applyFullSample(payload)
                    let delay = payload.hasRates ? interval : min(interval, Self.rateWarmupSeconds)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    private static func intervalSeconds(for mode: PollMode) -> TimeInterval {
        switch mode {
        case .stopped: return 0
        case .temperatureOnly(let interval), .full(let interval): return interval
        }
    }

    /// A sample that only re-armed the rate baselines carries no CPU load or disk rate; the
    /// last shown values stay until the next sample and nothing is added to the history.
    private func applyFullSample(_ payload: TelemetryFullSample) {
        updateCPUTemperature(payload.cpuTemperatureC)
        if let cpu = payload.cpu {
            cpuSample = cpu
            cpuRing.append(cpu)
            cpuHistory = cpuRing.elements
        }

        gpuSample = payload.gpu
        gpuRing.append(payload.gpu)
        gpuHistory = gpuRing.elements

        let rates = payload.diskRates ?? (disk.readBytesPerSec, disk.writeBytesPerSec)
        disk = payload.disk.withThroughput(readBytesPerSec: rates.read, writeBytesPerSec: rates.write)
        ram = payload.ram
    }

    /// Quantizes to 0.05°C steps so sub-0.01°C sensor jitter never triggers hidden
    /// Canvas redraws, and holds the last valid reading across brief transient `nil` reads.
    private func updateCPUTemperature(_ temp: Double?) {
        if let temp {
            consecutiveNilTempReads = 0
            let quantized = (temp * 20.0).rounded() / 20.0
            if let current = cpuTemperatureC, abs(current - quantized) < 0.05 {
                return
            }
            cpuTemperatureC = quantized
            return
        }
        consecutiveNilTempReads += 1
        if consecutiveNilTempReads >= 3, cpuTemperatureC != nil {
            cpuTemperatureC = nil
        }
    }

    private func setTemporaryFeedback(_ message: String) {
        freeMemoryFeedback = message
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.freeMemoryFeedback = nil
        }
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSleeping = true
                    self.reschedulePolling(immediate: false)
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSleeping = false
                    self.reschedulePolling(immediate: true)
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.areScreensAsleep = true
                    self.reschedulePolling(immediate: false)
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.areScreensAsleep = false
                    self.reschedulePolling(immediate: true)
                }
            }
        )

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isPanelVisible else { return }
                        self.refreshDiskVolumes()
                    }
                }
            )
        }
    }
}

// MARK: - Off-Main-Actor Telemetry Collector

private struct TelemetryFullSample: Sendable {
    /// Nil when this sample only re-armed the CPU tick baseline.
    let cpu: CPUSample?
    let cpuTemperatureC: Double?
    let gpu: GPUSample
    /// Capacity, temperature, and volumes; throughput is carried in `diskRates`.
    let disk: DiskSnapshot
    /// Nil when this sample only re-armed the disk byte-counter baseline.
    let diskRates: (read: Double, write: Double)?
    let ram: RAMSnapshot

    var hasRates: Bool { cpu != nil && diskRates != nil }
}

private actor TelemetryCollector {
    private struct CPUTicks {
        let user: UInt64
        let nice: UInt64
        let system: UInt64
        let idle: UInt64
    }

    private struct DiskIOSnapshot {
        let readBytes: UInt64
        let writeBytes: UInt64
        let timestamp: TimeInterval
    }

    private let totalRAMBytes: UInt64
    private let pageSize: UInt64
    private let hostPort: mach_port_t
    private var hostPortDeallocated = false
    private let smcReader = SMCTemperatureReader()

    private var cpuTicksBaseline = CounterBaseline<CPUTicks>()
    private var diskIOBaseline = CounterBaseline<DiskIOSnapshot>()
    private var cachedVolumes: [VolumeInfo] = []

    init(totalRAMBytes: UInt64) {
        self.totalRAMBytes = totalRAMBytes
        let rawPageSize = sysconf(_SC_PAGESIZE)
        self.pageSize = rawPageSize > 0 ? UInt64(rawPageSize) : 4096
        self.hostPort = mach_host_self()
    }

    func close() {
        smcReader.close()
        if !hostPortDeallocated, hostPort != MACH_PORT_NULL {
            mach_port_deallocate(mach_task_self_, hostPort)
            hostPortDeallocated = true
        }
    }

    func sampleTemperatureOnly() -> Double? {
        smcReader.readCPUTemperatureC()
    }

    func sampleFull(includeVolumes: Bool, resetRateBaselines: Bool) -> TelemetryFullSample {
        if resetRateBaselines {
            cpuTicksBaseline.reset()
            diskIOBaseline.reset()
        }
        let cpuTemperatureC = smcReader.readCPUTemperatureC()
        let cpu = sampleCPU(temperatureC: cpuTemperatureC)
        let gpu = sampleGPU()
        let disk = sampleDiskCapacity(includeVolumes: includeVolumes)
        let diskRates = sampleDiskThroughput()
        let ram = sampleRAM()
        return TelemetryFullSample(
            cpu: cpu,
            cpuTemperatureC: cpuTemperatureC,
            gpu: gpu,
            disk: disk,
            diskRates: diskRates,
            ram: ram
        )
    }

    func sampleRAM() -> RAMSnapshot {
        guard !hostPortDeallocated, hostPort != MACH_PORT_NULL else { return .empty }
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .empty }

        let pressure = TelemetryHardwareInfo.readMemoryPressureLevel()
        let counts = VMPageCounts(
            totalBytes: totalRAMBytes,
            pageSize: pageSize,
            activePages: UInt64(vmStats.active_count),
            inactivePages: UInt64(vmStats.inactive_count),
            speculativePages: UInt64(vmStats.speculative_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressedPages: UInt64(vmStats.compressor_page_count),
            purgeablePages: UInt64(vmStats.purgeable_count),
            externalPages: UInt64(vmStats.external_page_count),
            pressureLevel: pressure
        )
        return RAMSnapshot.from(vmCounts: counts)
    }

    /// Primary-volume capacity, disk temperature, and volumes. Throughput is left at zero:
    /// it is a rate between two samples, which only the polling loop's baseline can give.
    func sampleDiskCapacity(includeVolumes: Bool) -> DiskSnapshot {
        let rootURL = URL(fileURLWithPath: "/")
        let rootKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        let rootValues = try? rootURL.resourceValues(forKeys: rootKeys)
        let name = rootValues?.volumeName ?? "Macintosh HD"
        let total = UInt64(max(0, rootValues?.volumeTotalCapacity ?? 0))
        let available: UInt64
        if let important = rootValues?.volumeAvailableCapacityForImportantUsage, important >= 0 {
            available = UInt64(important)
        } else if let basic = rootValues?.volumeAvailableCapacity, basic >= 0 {
            available = UInt64(basic)
        } else {
            available = 0
        }
        let used = total > available ? total - available : 0

        if includeVolumes || cachedVolumes.isEmpty {
            cachedVolumes = enumerateVolumes()
        }

        let tempC = smcReader.readDiskTemperatureC()

        return DiskSnapshot(
            name: name,
            usedBytes: used,
            totalBytes: total,
            readBytesPerSec: 0,
            writeBytesPerSec: 0,
            temperatureC: tempC,
            volumes: cachedVolumes,
            usedFraction: VolumeInfo.clampedFraction(usedBytes: used, totalBytes: total)
        )
    }

    // MARK: - CPU Sampling

    private func sampleCPU(temperatureC tempC: Double?) -> CPUSample? {
        guard let reading = readTotalCPUTicks() else {
            return CPUSample(user: 0, system: 0, idle: 100, temperatureC: tempC)
        }
        guard let (previous, current) = cpuTicksBaseline.advance(to: reading) else {
            return nil
        }

        let dUser = current.user >= previous.user ? current.user - previous.user : 0
        let dNice = current.nice >= previous.nice ? current.nice - previous.nice : 0
        let dSystem = current.system >= previous.system ? current.system - previous.system : 0
        let dIdle = current.idle >= previous.idle ? current.idle - previous.idle : 0

        return CPUSample.fromTickDeltas(
            user: dUser,
            nice: dNice,
            system: dSystem,
            idle: dIdle,
            temperatureC: tempC
        )
    }

    private func readTotalCPUTicks() -> CPUTicks? {
        guard !hostPortDeallocated, hostPort != MACH_PORT_NULL else { return nil }
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoArray else { return nil }
        defer {
            let byteSize = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteSize)
        }

        let stride = Int(CPU_STATE_MAX)
        var user: UInt64 = 0
        var nice: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0

        for core in 0..<Int(cpuCount) {
            let base = core * stride
            user &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            nice &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            system &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        }
        return CPUTicks(user: user, nice: nice, system: system, idle: idle)
    }

    // MARK: - GPU Sampling

    private func sampleGPU() -> GPUSample {
        guard let matching = IOServiceMatching("IOAccelerator") else { return .zero }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return .zero
        }
        defer { IOObjectRelease(iterator) }

        var best = GPUSample.zero
        var foundAny = false

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let statsRef = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            ), let stats = statsRef.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let device = Self.numericValue(stats["Device Utilization %"])
                ?? Self.numericValue(stats["GPU Core Utilization"])
                ?? 0
            let render = Self.numericValue(stats["Renderer Utilization %"]) ?? 0
            let tiler = Self.numericValue(stats["Tiler Utilization %"]) ?? 0
            let candidate = GPUSample(device: device, render: render, tiler: tiler)

            if !foundAny || candidate.device > best.device {
                best = candidate
                foundAny = true
            }
        }
        return best
    }

    private static func numericValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    // MARK: - Disk Throughput & Volumes

    private func sampleDiskThroughput() -> (read: Double, write: Double)? {
        let (totalRead, totalWrite) = readTotalBlockStorageBytes()
        let now = ProcessInfo.processInfo.systemUptime
        let reading = DiskIOSnapshot(readBytes: totalRead, writeBytes: totalWrite, timestamp: now)
        guard let (previous, current) = diskIOBaseline.advance(to: reading) else { return nil }

        let dt = current.timestamp - previous.timestamp
        guard dt > 0.05 else { return (0, 0) }

        let dRead = current.readBytes >= previous.readBytes ? Double(current.readBytes - previous.readBytes) : 0
        let dWrite = current.writeBytes >= previous.writeBytes ? Double(current.writeBytes - previous.writeBytes) : 0
        return (dRead / dt, dWrite / dt)
    }

    private func readTotalBlockStorageBytes() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let statsRef = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            ), let stats = statsRef.takeRetainedValue() as? [String: Any] else {
                continue
            }
            if let readNum = stats["Bytes (Read)"] as? NSNumber {
                totalRead &+= readNum.uint64Value
            }
            if let writeNum = stats["Bytes (Write)"] as? NSNumber {
                totalWrite &+= writeNum.uint64Value
            }
        }
        return (totalRead, totalWrite)
    }

    private func enumerateVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var seenPaths: Set<String> = []
        var volumes: [VolumeInfo] = []

        for url in urls {
            let path = url.path
            guard seenPaths.insert(path).inserted else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            guard total > 0 else { continue }

            let available: UInt64
            if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
                available = UInt64(important)
            } else if let basic = values.volumeAvailableCapacity, basic >= 0 {
                available = UInt64(basic)
            } else {
                available = 0
            }
            let used = total > available ? total - available : 0
            let name = values.volumeName ?? url.lastPathComponent
            let fsName = values.volumeLocalizedFormatDescription ?? Self.readFileSystemType(at: path)
            let isInternal = values.volumeIsInternal ?? (path == "/")

            volumes.append(
                VolumeInfo(
                    id: path,
                    name: name,
                    mountPath: path,
                    fileSystem: fsName,
                    usedBytes: used,
                    totalBytes: total,
                    isInternal: isInternal,
                    usedFraction: VolumeInfo.clampedFraction(usedBytes: used, totalBytes: total)
                )
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func readFileSystemType(at path: String) -> String {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return "APFS" }
        let name = withUnsafeBytes(of: &stats.f_fstypename) { raw -> String in
            let bytes = Array(raw.prefix { $0 != 0 })
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return name.isEmpty ? "APFS" : name.uppercased()
    }
}

// MARK: - Static Hardware Metadata Helpers

private enum TelemetryHardwareInfo {
    static func readCPUModelName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            #if arch(arm64)
            return "Apple Silicon"
            #else
            return "Intel Mac"
            #endif
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Mac CPU"
        }
        let utf8Bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let raw = String(bytes: utf8Bytes, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac CPU" : trimmed
    }

    static func readTotalRAMBytes() -> UInt64 {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memSize, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.physicalMemory
        }
        return memSize
    }

    static func readMemoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 0
        }
        return Int(level)
    }

    static func readGPUInfo(fallbackModel: String) -> (modelName: String, coreCount: Int) {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return (fallbackModel, 0)
        }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return (fallbackModel, 0)
        }
        defer { IOObjectRelease(iterator) }

        var modelName = fallbackModel
        var coreCount = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            if let modelRef = IORegistryEntryCreateCFProperty(
                service, "model" as CFString, kCFAllocatorDefault, 0
            ), let model = modelRef.takeRetainedValue() as? String, !model.isEmpty {
                modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let coreRef = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            ) {
                let rawValue = coreRef.takeRetainedValue()
                if let num = rawValue as? NSNumber {
                    coreCount = max(coreCount, num.intValue)
                } else if let data = rawValue as? Data, data.count >= 4 {
                    let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                    coreCount = max(coreCount, Int(value))
                }
            }
        }
        return (modelName, coreCount)
    }
}
