import Foundation

struct SmartVirtualDisplayConfig: Codable, Equatable, Sendable {
    static let defaultID = UUID(uuid: (
        0x53, 0x4D, 0x41, 0x52,
        0x54, 0x44, 0x55, 0x4D,
        0x4D, 0x59, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    ))

    let id: UUID
    var isEnabled: Bool
    var clamshellGuardEnabled: Bool
    var name: String
    var width: Int
    var height: Int
    var refreshRate: Double
    var hiDPI: Bool
    var startsHiDPI: Bool

    init(
        id: UUID = Self.defaultID,
        isEnabled: Bool = false,
        clamshellGuardEnabled: Bool = true,
        name: String = "Smart Dummy",
        width: Int = 3200,
        height: Int = 2000,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true,
        startsHiDPI: Bool = true
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.clamshellGuardEnabled = clamshellGuardEnabled
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.startsHiDPI = startsHiDPI
    }

    var productID: UInt32 {
        let bytes = id.uuid
        return UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }

    var serialNumber: UInt32 {
        let bytes = id.uuid
        return UInt32(bytes.4) << 24 | UInt32(bytes.5) << 16 | UInt32(bytes.6) << 8 | UInt32(bytes.7)
    }

    var displayUUID: String {
        CrispVirtualDisplayIdentity.uuid(productID: productID, serialNumber: serialNumber)
    }

    var supportsHiDPI: Bool {
        hiDPI && width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }

    var effectiveStartsHiDPI: Bool {
        startsHiDPI && supportsHiDPI
    }

    var logicalWidth: Int {
        effectiveStartsHiDPI ? width / 2 : width
    }

    var logicalHeight: Int {
        effectiveStartsHiDPI ? height / 2 : height
    }
}

struct SmartVirtualDisplayInput: Equatable, Sendable {
    let isOnACPower: Bool
    let isClamshellClosed: Bool
    let activePhysicalExternalCount: Int
    let activeBuiltinCount: Int

    init(
        isOnACPower: Bool = false,
        isClamshellClosed: Bool = false,
        activePhysicalExternalCount: Int = 0,
        activeBuiltinCount: Int = 0
    ) {
        self.isOnACPower = isOnACPower
        self.isClamshellClosed = isClamshellClosed
        self.activePhysicalExternalCount = activePhysicalExternalCount
        self.activeBuiltinCount = activeBuiltinCount
    }
}

enum SmartVirtualDisplayPhase: String, Codable, Equatable, Sendable {
    case disabled
    case suspendedOnBattery
    case armedStandby
    case activeMounted
}

struct SmartVirtualDisplayDecision: Equatable, Sendable {
    let phase: SmartVirtualDisplayPhase
    let shouldMountVirtualDisplay: Bool
    let shouldDisableClamshellSleep: Bool
    let shouldHoldSystemSleepAssertion: Bool
    let shouldHoldDisplaySleepAssertion: Bool
}

enum SmartVirtualDisplayPolicy {
    static func resolveExternalPhysicalCount(
        cgOnlineExternalCount: Int,
        kernelExternalCount: Int?,
        softDisconnectedExternalCount: Int,
        areScreensAsleep: Bool
    ) -> Int {
        let cgCount = max(0, cgOnlineExternalCount)
        let softCount = max(0, softDisconnectedExternalCount)
        if areScreensAsleep {
            return cgCount
        }
        guard let kernel = kernelExternalCount else {
            return cgCount
        }
        if kernel <= 0 {
            return 0
        }
        if softCount == 0 {
            return max(cgCount, kernel)
        }
        return max(cgCount, max(0, kernel - softCount))
    }

    static func evaluate(
        config: SmartVirtualDisplayConfig,
        input: SmartVirtualDisplayInput
    ) -> SmartVirtualDisplayDecision {
        guard config.isEnabled else {
            return SmartVirtualDisplayDecision(
                phase: .disabled,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        }

        guard input.isOnACPower else {
            return SmartVirtualDisplayDecision(
                phase: .suspendedOnBattery,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        }

        let hasUsablePhysical = (input.activePhysicalExternalCount > 0)
            || (!input.isClamshellClosed && input.activeBuiltinCount > 0)

        if hasUsablePhysical {
            let guardArmed = config.clamshellGuardEnabled && input.isClamshellClosed
            return SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: guardArmed,
                shouldHoldSystemSleepAssertion: guardArmed,
                shouldHoldDisplaySleepAssertion: false
            )
        }

        return SmartVirtualDisplayDecision(
            phase: .activeMounted,
            shouldMountVirtualDisplay: true,
            shouldDisableClamshellSleep: config.clamshellGuardEnabled && input.isClamshellClosed,
            shouldHoldSystemSleepAssertion: config.clamshellGuardEnabled,
            shouldHoldDisplaySleepAssertion: config.clamshellGuardEnabled
        )
    }
}
