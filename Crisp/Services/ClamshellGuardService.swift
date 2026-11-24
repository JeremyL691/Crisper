import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

private let kPMSetClamshellSleepStateSelector: UInt32 = 12
private let kIOMessageCanSystemSleepCode: UInt32 = 0xE000_0270
private let kIOMessageSystemWillSleepCode: UInt32 = 0xE000_0280
private let kIOMessageSystemHasPoweredOnCode: UInt32 = 0xE000_0300
private let kIOMessageSystemWillPowerOnCode: UInt32 = 0xE000_0320

private func clamshellSystemPowerCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    _ = service
    guard let refCon else { return }
    let notifID = Int(bitPattern: messageArgument)
    let guardService = Unmanaged<ClamshellGuardService>.fromOpaque(refCon).takeUnretainedValue()
    MainActor.assumeIsolated {
        guardService.handleSystemPowerMessage(messageType, notificationID: notifID)
    }
}

/// Manages IOPMrootDomain clamshell sleep override (Selector 12), SensorsActive powerd
/// assertions, and the IORegisterForSystemPower sleep-veto/wake client.
@MainActor
final class ClamshellGuardService {
    static let shared = ClamshellGuardService()

    private static let log = Logger(subsystem: "com.crisper.app", category: "clamshell-guard")
    private static let tickleIntervalSeconds: TimeInterval = 60.0

    var onSystemWake: (() -> Void)?
    var onPowerWakePreSync: (() -> Void)?
    var shouldPreArmClamshellOnACWake: (() -> Bool)?
    var shouldPromoteHeadlessACWake: (() -> Bool)?

    private(set) var clamshellSleepDisabled = false
    private(set) var systemSleepAssertionHeld = false
    private(set) var displaySleepAssertionHeld = false

    private var sysSleepAssertion: IOPMAssertionID = 0
    private var dispSleepAssertion: IOPMAssertionID = 0
    private var userActAssertion: IOPMAssertionID = 0
    private var userTickleAssertion: IOPMAssertionID = 0
    private var lastTickleTime: CFAbsoluteTime = 0
    private var tickleTimer: Timer?

    private var rootDomainConn: io_connect_t = IO_OBJECT_NULL
    private var sysPowerConn: io_connect_t = IO_OBJECT_NULL
    private var sysPowerNotifier: io_object_t = IO_OBJECT_NULL
    private var sysPowerNotifyPort: IONotificationPortRef?
    private var powerClientRegistered = false
    private var powerClientContext: UnsafeMutableRawPointer?

    func start() {
        guard !powerClientRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = IO_OBJECT_NULL
        let conn = IORegisterForSystemPower(
            context,
            &notifyPort,
            clamshellSystemPowerCallback,
            &notifier
        )
        guard conn != IO_OBJECT_NULL, let port = notifyPort else {
            Self.log.error("IORegisterForSystemPower failed")
            return
        }
        sysPowerConn = conn
        sysPowerNotifyPort = port
        sysPowerNotifier = notifier
        powerClientContext = context
        powerClientRegistered = true
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func apply(decision: SmartVirtualDisplayDecision, forceTickle: Bool = false) {
        sync(
            disableClamshellSleep: decision.shouldDisableClamshellSleep,
            holdSystemSleep: decision.shouldHoldSystemSleepAssertion,
            holdDisplaySleep: decision.shouldHoldDisplaySleepAssertion,
            forceTickle: forceTickle
        )
    }

    func sync(
        disableClamshellSleep: Bool,
        holdSystemSleep: Bool,
        holdDisplaySleep: Bool,
        forceTickle: Bool = false
    ) {
        let enteredDisplayHold = holdDisplaySleep && !displaySleepAssertionHeld

        // System idle sleep assertion (SensorsActive)
        if holdSystemSleep {
            ensureAssertion(
                id: &sysSleepAssertion,
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                name: "Crisper Smart Dummy Clamshell Keep-Alive"
            )
            systemSleepAssertionHeld = (sysSleepAssertion != 0)
        } else {
            releaseAssertion(&sysSleepAssertion)
            systemSleepAssertionHeld = false
        }

        // Display idle sleep + UserIsActive assertions: NEVER hold when decision says false.
        if holdDisplaySleep {
            ensureAssertion(
                id: &dispSleepAssertion,
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                name: "Crisper Smart Dummy Display Keep-Alive"
            )
            ensureAssertion(
                id: &userActAssertion,
                type: "UserIsActive",
                name: "Crisper Smart Dummy UserActive"
            )
            displaySleepAssertionHeld = (dispSleepAssertion != 0 || userActAssertion != 0)
            tickleDisplayWake(force: forceTickle || enteredDisplayHold)
            startTickleTimerIfNeeded()
        } else {
            stopTickleTimer()
            releaseAssertion(&dispSleepAssertion)
            releaseAssertion(&userActAssertion)
            releaseAssertion(&userTickleAssertion)
            lastTickleTime = 0
            displaySleepAssertionHeld = false
        }

        // IOPMrootDomain UserClient Selector 12 (kPMSetClamshellSleepState)
        if disableClamshellSleep {
            setRootDomainClamshellSleepDisabled(true)
            clamshellSleepDisabled = true
        } else if clamshellSleepDisabled {
            setRootDomainClamshellSleepDisabled(false)
            clamshellSleepDisabled = false
        }
    }

    /// Re-asserts Selector 12 synchronously on hotplug/clamshell callbacks while armed.
    func reinforceIfArmed() {
        guard clamshellSleepDisabled else { return }
        setRootDomainClamshellSleepDisabled(true)
    }

    func tickleDisplayWake(force: Bool = false) {
        guard displaySleepAssertionHeld else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard force || userTickleAssertion == 0 || (now - lastTickleTime) >= Self.tickleIntervalSeconds else {
            return
        }
        var rc = IOPMAssertionDeclareUserActivity(
            "Crisper Smart Dummy Display Wake" as CFString,
            kIOPMUserActiveLocal,
            &userTickleAssertion
        )
        if rc != kIOReturnSuccess && userTickleAssertion != 0 {
            IOPMAssertionRelease(userTickleAssertion)
            userTickleAssertion = 0
            rc = IOPMAssertionDeclareUserActivity(
                "Crisper Smart Dummy Display Wake" as CFString,
                kIOPMUserActiveLocal,
                &userTickleAssertion
            )
        }
        if rc == kIOReturnSuccess {
            lastTickleTime = now
        }
    }

    /// Resets kernel global IOPMrootDomain Selector 12 (`setDisableClamShellSleep(false)`) at
    /// startup when the guard is not actively needed, recovering cleanly from a prior crash/SIGKILL.
    func resetStaleDisableIfNeeded() {
        guard !clamshellSleepDisabled else { return }
        setRootDomainClamshellSleepDisabled(false)
        if rootDomainConn != IO_OBJECT_NULL {
            IOServiceClose(rootDomainConn)
            rootDomainConn = IO_OBJECT_NULL
        }
        Self.log.notice("Reset stale IOPMrootDomain clamshell-sleep disable state at startup")
    }

    /// Releases all power assertions and restores normal clamshell sleep synchronously.
    func releaseAll() {
        stopTickleTimer()
        releaseAssertion(&sysSleepAssertion)
        releaseAssertion(&dispSleepAssertion)
        releaseAssertion(&userActAssertion)
        releaseAssertion(&userTickleAssertion)
        lastTickleTime = 0
        systemSleepAssertionHeld = false
        displaySleepAssertionHeld = false

        if clamshellSleepDisabled || rootDomainConn != IO_OBJECT_NULL {
            setRootDomainClamshellSleepDisabled(false)
        }
        clamshellSleepDisabled = false
    }

    /// Synchronous teardown called on app termination.
    func shutdown() {
        releaseAll()

        if rootDomainConn != IO_OBJECT_NULL {
            IOServiceClose(rootDomainConn)
            rootDomainConn = IO_OBJECT_NULL
        }

        if powerClientRegistered {
            if let port = sysPowerNotifyPort {
                let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if sysPowerNotifier != IO_OBJECT_NULL {
                IODeregisterForSystemPower(&sysPowerNotifier)
                sysPowerNotifier = IO_OBJECT_NULL
            }
            if let port = sysPowerNotifyPort {
                IONotificationPortDestroy(port)
                sysPowerNotifyPort = nil
            }
            if sysPowerConn != IO_OBJECT_NULL {
                IOServiceClose(sysPowerConn)
                sysPowerConn = IO_OBJECT_NULL
            }
            powerClientContext = nil
            powerClientRegistered = false
        }
    }

    // MARK: - System Power Callback

    fileprivate func handleSystemPowerMessage(_ messageType: UInt32, notificationID notifID: Int) {
        switch messageType {
        case kIOMessageCanSystemSleepCode:
            let shouldVeto = clamshellSleepDisabled || (shouldPreArmClamshellOnACWake?() == true)
            if shouldVeto {
                setRootDomainClamshellSleepDisabled(true)
                clamshellSleepDisabled = true
                if displaySleepAssertionHeld {
                    tickleDisplayWake(force: true)
                }
                IOCancelPowerChange(sysPowerConn, notifID)
            } else {
                IOAllowPowerChange(sysPowerConn, notifID)
            }
        case kIOMessageSystemWillSleepCode:
            IOAllowPowerChange(sysPowerConn, notifID)
        case kIOMessageSystemWillPowerOnCode:
            preArmForWakeIfNeeded()
        case kIOMessageSystemHasPoweredOnCode:
            preArmForWakeIfNeeded()
            onSystemWake?()
        default:
            break
        }
    }

    private func preArmForWakeIfNeeded() {
        onPowerWakePreSync?()
        let preArm = shouldPreArmClamshellOnACWake?() == true
        guard clamshellSleepDisabled || preArm else { return }
        setRootDomainClamshellSleepDisabled(true)
        clamshellSleepDisabled = true
        ensureAssertion(
            id: &sysSleepAssertion,
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            name: "Crisper Smart Dummy Clamshell Keep-Alive"
        )
        systemSleepAssertionHeld = (sysSleepAssertion != 0)
        if displaySleepAssertionHeld {
            tickleDisplayWake(force: true)
        } else if shouldPromoteHeadlessACWake?() == true {
            declareWakePromotionUserActivity()
        }
    }

    private func declareWakePromotionUserActivity() {
        releaseAssertion(&userTickleAssertion)
        let rc = IOPMAssertionDeclareUserActivity(
            "Crisper Smart Dummy Display Wake" as CFString,
            kIOPMUserActiveLocal,
            &userTickleAssertion
        )
        if rc == kIOReturnSuccess {
            lastTickleTime = CFAbsoluteTimeGetCurrent()
        }
    }

    // MARK: - Private Helpers

    private func startTickleTimerIfNeeded() {
        guard tickleTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickleIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickleDisplayWake(force: false)
            }
        }
        timer.tolerance = 5.0
        RunLoop.main.add(timer, forMode: .common)
        tickleTimer = timer
    }

    private func stopTickleTimer() {
        tickleTimer?.invalidate()
        tickleTimer = nil
    }

    private func ensureAssertion(id: inout IOPMAssertionID, type: String, name: String) {
        guard id == 0 else { return }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            "SensorsActive": true
        ]
        var createdID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithProperties(properties as CFDictionary, &createdID)
        if rc == kIOReturnSuccess {
            id = createdID
        } else {
            Self.log.error("IOPMAssertionCreateWithProperties(\(type, privacy: .public)) failed: \(rc, privacy: .public)")
        }
    }

    private func releaseAssertion(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    private func setRootDomainClamshellSleepDisabled(_ disableSleep: Bool) {
        for _ in 0..<2 {
            if rootDomainConn == IO_OBJECT_NULL {
                let rootDomain = IOServiceGetMatchingService(
                    kIOMainPortDefault,
                    IOServiceMatching("IOPMrootDomain")
                )
                if rootDomain != IO_OBJECT_NULL {
                    IOServiceOpen(rootDomain, mach_task_self_, 0, &rootDomainConn)
                    IOObjectRelease(rootDomain)
                }
            }
            guard rootDomainConn != IO_OBJECT_NULL else { break }
            var inScalar: UInt64 = disableSleep ? 1 : 0
            var outCount: UInt32 = 0
            let kr = IOConnectCallScalarMethod(
                rootDomainConn,
                kPMSetClamshellSleepStateSelector,
                &inScalar,
                1,
                nil,
                &outCount
            )
            if kr == KERN_SUCCESS {
                break
            }
            IOServiceClose(rootDomainConn)
            rootDomainConn = IO_OBJECT_NULL
        }
    }
}
