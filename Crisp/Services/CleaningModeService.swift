import AppKit
import ApplicationServices
import CoreGraphics
import os.log
import SwiftUI

// MARK: - C Event Tap Callback

private func cleaningEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<CleaningModeService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - CleaningMode

enum CleaningMode: Equatable, Sendable {
    case none
    case keyboard
    case screen
}

// MARK: - CleaningModeService

/// Manages Clean Keyboard (keyboard lock + floating glass HUD) and Clean Screen (pure-black
/// multi-monitor blackout + subtle exit pill). Guarantees foolproof unlock on hold-key,
/// mouse unlock, tap timeout, Accessibility revoke, screen disconnect, sleep, and termination.
@MainActor
final class CleaningModeService: ObservableObject {
    static let shared = CleaningModeService()

    @Published private(set) var activeMode: CleaningMode = .none
    @Published private(set) var interceptedKeyCount: Int = 0
    @Published var lastError: String? = nil
    @Published private(set) var exitHoldProgress: Double = 0.0
    @Published private(set) var isScreenPillRevealed: Bool = false
    @Published private(set) var isHoveringScreenPill: Bool = false

    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "cleaning")
    private nonisolated static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    private nonisolated static let escapeKeyCode: Int64 = 53
    private static let holdExitDuration: TimeInterval = 1.5
    private static let screenPillDimDelay: TimeInterval = 5.0

    // Event tap state
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selfRetained: Unmanaged<CleaningModeService>?

    // Timers & monitors
    private var trustWatchdog: Timer?
    private var holdExitTimer: Timer?
    private var holdExitStartUptime: TimeInterval?
    private var screenPillDimTimer: Timer?
    private var focusVerificationTask: Task<Void, Never>?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    // System observers & display tracking
    private var screenParamsObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var didResignActiveObserver: NSObjectProtocol?
    private var activeScreenIDs: Set<CGDirectDisplayID> = []

    // UI windows & balanced cursor guard
    private var keyboardHUDPanel: NSPanel?
    private var screenOverlayWindows: [CleaningOverlayWindow] = []
    private var isCursorHidden = false

    private init() {}

    // MARK: - Public API

    func toggleKeyboardCleaning() {
        if activeMode == .keyboard {
            stopAll()
        } else {
            startKeyboardCleaning()
        }
    }

    func toggleScreenCleaning() {
        if activeMode == .screen {
            stopAll()
        } else {
            startScreenCleaning()
        }
    }

    func startKeyboardCleaning() {
        lastError = nil
        if activeMode != .none {
            stopAll()
        }

        guard AXIsProcessTrusted() else {
            BrightnessKeyService.requestAccess()
            lastError = String(localized: "Accessibility permission is required to lock the keyboard.")
            return
        }

        guard installKeyboardTap() else {
            BrightnessKeyService.requestAccess()
            lastError = String(localized: "Could not lock the keyboard. Re-enable Accessibility permission for Crisper.")
            return
        }

        activeMode = .keyboard
        activeScreenIDs = Self.currentDisplayIDs()
        interceptedKeyCount = 0
        exitHoldProgress = 0.0
        installSystemObservers()
        startTrustWatchdog()
        showKeyboardHUD()
        Self.log.notice("Clean Keyboard started")
    }

    func startScreenCleaning() {
        lastError = nil
        if activeMode != .none {
            stopAll()
        }

        guard !NSScreen.screens.isEmpty else {
            lastError = String(localized: "No displays available for Clean Screen.")
            return
        }

        activeMode = .screen
        activeScreenIDs = Self.currentDisplayIDs()
        interceptedKeyCount = 0
        exitHoldProgress = 0.0
        isScreenPillRevealed = true
        isHoveringScreenPill = false

        installSystemObservers()
        if AXIsProcessTrusted(), installKeyboardTap() {
            startTrustWatchdog()
        }

        let primaryWindow = showScreenOverlays(animated: true)
        installLocalScreenMonitor()
        hideCursorIfNeeded()
        scheduleScreenPillDim()
        scheduleFocusVerificationIfNeeded(
            primaryWindow: primaryWindow,
            onFailureMessage: String(
                localized: "Clean Screen could not capture focus. Grant Accessibility access or close any password prompt."
            )
        )
        Self.log.notice("Clean Screen started")
    }

    /// Synchronously tears down all taps, windows, observers, timers, and restores cursor visibility.
    func stopAll() {
        let wasActive = activeMode != .none
        focusVerificationTask?.cancel()
        focusVerificationTask = nil
        cancelHoldExit()
        stopTrustWatchdog()
        stopScreenPillDimTimer()
        tearDownKeyboardTap()
        removeLocalEventMonitor()
        removeSystemObservers()
        closeKeyboardHUD()
        closeScreenOverlays()
        unhideCursorIfNeeded()

        activeMode = .none
        activeScreenIDs.removeAll()
        interceptedKeyCount = 0
        exitHoldProgress = 0.0
        isScreenPillRevealed = false
        isHoveringScreenPill = false

        if wasActive {
            Self.log.notice("Cleaning mode stopped")
        }
    }

    // MARK: - Balanced Cursor Visibility

    private func hideCursorIfNeeded() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func unhideCursorIfNeeded() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }

    // MARK: - Keyboard Event Tap

    private func installKeyboardTap() -> Bool {
        guard eventTap == nil else { return true }

        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cleaningEventTapCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap else {
            retained.release()
            selfRetained = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    private func tearDownKeyboardTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        selfRetained?.release()
        selfRetained = nil
    }

    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            Self.log.notice("Cleaning key tap disabled by system (\(reason, privacy: .public))")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handleTapDisabled() }
            }
            return Unmanaged.passUnretained(event)
        }

        let typeRaw = type.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flagsRaw = event.flags.rawValue
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Registered on the main run loop, so assumeIsolated executes synchronously on MainActor.
        let shouldConsume = MainActor.assumeIsolated {
            self.processTappedEvent(
                typeRaw: typeRaw,
                keyCode: keyCode,
                flagsRaw: flagsRaw,
                isAutoRepeat: isAutoRepeat
            )
        }
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func processTappedEvent(
        typeRaw: UInt32,
        keyCode: Int64,
        flagsRaw: UInt64,
        isAutoRepeat: Bool
    ) -> Bool {
        guard activeMode != .none else { return false }

        let flags = CGEventFlags(rawValue: flagsRaw)
        switch typeRaw {
        case CGEventType.keyDown.rawValue:
            if !isAutoRepeat {
                interceptedKeyCount += 1
            }
            handleKeyDown(keyCode: keyCode, flags: flags)
            return true
        case CGEventType.keyUp.rawValue:
            if keyCode == Self.escapeKeyCode {
                cancelHoldExit()
            }
            return true
        case CGEventType.flagsChanged.rawValue:
            if activeMode == .keyboard, holdExitStartUptime != nil {
                let required: CGEventFlags = [.maskCommand, .maskAlternate]
                if !flags.contains(required) {
                    cancelHoldExit()
                }
            }
            return true
        case Self.cgEventTypeSystemDefinedRaw:
            // Swallow NX_SYSDEFINED (media, brightness, volume keys) while cleaning.
            return true
        default:
            return false
        }
    }

    private func handleKeyDown(keyCode: Int64, flags: CGEventFlags) {
        guard keyCode == Self.escapeKeyCode else { return }

        switch activeMode {
        case .keyboard:
            let required: CGEventFlags = [.maskCommand, .maskAlternate]
            if flags.contains(required) {
                beginHoldExit()
            }
        case .screen:
            revealScreenPillTemporarily()
            beginHoldExit()
        case .none:
            break
        }
    }

    private func handleTapDisabled() {
        guard activeMode != .none else { return }

        if !AXIsProcessTrusted() {
            Self.log.notice("Cleaning key tap disabled after Accessibility trust dropped; unlocking")
            if activeMode == .keyboard {
                lastError = String(localized: "Accessibility permission was revoked; keyboard unlocked.")
            }
            stopAll()
            return
        }

        // Unlock immediately on tap timeout/disable instead of re-enabling, preventing
        // system-wide input freezes if TCC revokes trust mid-session.
        Self.log.error("Cleaning key tap disabled by system; unlocking immediately to prevent stuck input")
        if activeMode == .keyboard {
            lastError = String(localized: "Keyboard lock ended automatically after the event tap timed out.")
        }
        stopAll()
    }

    // MARK: - Hold-to-Exit Timer

    private func beginHoldExit() {
        guard holdExitStartUptime == nil else { return }
        holdExitStartUptime = ProcessInfo.processInfo.systemUptime
        exitHoldProgress = 0.02

        holdExitTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let start = self.holdExitStartUptime else {
                    self.cancelHoldExit()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let progress = min(1.0, max(0.0, elapsed / Self.holdExitDuration))
                self.exitHoldProgress = progress
                if elapsed >= Self.holdExitDuration {
                    self.stopAll()
                }
            }
        }
    }

    private func cancelHoldExit() {
        holdExitTimer?.invalidate()
        holdExitTimer = nil
        holdExitStartUptime = nil
        if exitHoldProgress != 0.0 {
            exitHoldProgress = 0.0
        }
    }

    // MARK: - Accessibility Trust Watchdog

    private func startTrustWatchdog() {
        guard trustWatchdog == nil else { return }
        trustWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.eventTap != nil, !AXIsProcessTrusted() else { return }
                Self.log.notice("Accessibility trust dropped during cleaning mode")
                if self.activeMode == .keyboard {
                    self.lastError = String(localized: "Accessibility permission was revoked; keyboard unlocked.")
                    self.stopAll()
                } else {
                    self.tearDownKeyboardTap()
                    self.stopTrustWatchdog()
                }
            }
        }
    }

    private func stopTrustWatchdog() {
        trustWatchdog?.invalidate()
        trustWatchdog = nil
    }

    // MARK: - System Observers

    private func installSystemObservers() {
        removeSystemObservers()

        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        }

        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }

        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }

        didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeMode == .screen else { return }
                Self.log.notice("Application resigned active during Clean Screen; unlocking")
                self.stopAll()
            }
        }
    }

    private func removeSystemObservers() {
        if let obs = screenParamsObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParamsObserver = nil
        }
        if let obs = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            willSleepObserver = nil
        }
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
            willTerminateObserver = nil
        }
        if let obs = didResignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            didResignActiveObserver = nil
        }
    }

    private static func currentDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
        })
    }

    private func handleScreenParametersChanged() {
        let currentIDs = Self.currentDisplayIDs()
        switch activeMode {
        case .keyboard:
            guard !NSScreen.screens.isEmpty else {
                Self.log.notice("All displays disconnected during Clean Keyboard; unlocking")
                stopAll()
                return
            }
            activeScreenIDs = currentIDs
            repositionKeyboardHUD()
        case .screen:
            guard !NSScreen.screens.isEmpty, activeScreenIDs.isSubset(of: currentIDs) else {
                Self.log.notice("Display disconnected during Clean Screen; unlocking")
                stopAll()
                return
            }
            activeScreenIDs = currentIDs
            closeScreenOverlays()
            let primaryWindow = showScreenOverlays(animated: false)
            scheduleFocusVerificationIfNeeded(primaryWindow: primaryWindow, onFailureMessage: nil)
        case .none:
            break
        }
    }

    /// Defers the key-window focus check so WindowServer has time to finish activating our
    /// LSUIElement app asynchronously after `NSApp.activate(ignoringOtherApps: true)`.
    private func scheduleFocusVerificationIfNeeded(
        primaryWindow: CleaningOverlayWindow?,
        onFailureMessage: String?
    ) {
        focusVerificationTask?.cancel()
        focusVerificationTask = nil
        guard eventTap == nil else { return }
        focusVerificationTask = Task { @MainActor [weak self, weak primaryWindow] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, self.activeMode == .screen, self.eventTap == nil else { return }
            if primaryWindow?.isKeyWindow != true {
                Self.log.notice("Clean Screen could not acquire key window focus without Accessibility; aborting safely")
                self.stopAll()
                if let onFailureMessage {
                    self.lastError = onFailureMessage
                }
            }
        }
    }

    // MARK: - Clean Keyboard HUD

    private func showKeyboardHUD() {
        closeKeyboardHUD()

        let hudView = CleanKeyboardHUDView(service: self)
        let hostingView = NSHostingView(rootView: hudView)
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: max(320, fittingSize.width), height: max(68, fittingSize.height))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hostingView

        keyboardHUDPanel = panel
        repositionKeyboardHUD()
        panel.orderFrontRegardless()
    }

    private func repositionKeyboardHUD() {
        guard let panel = keyboardHUDPanel,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: round(frame.midX - size.width / 2),
            y: round(frame.maxY - size.height - 16)
        )
        panel.setFrameOrigin(origin)
    }

    private func closeKeyboardHUD() {
        keyboardHUDPanel?.orderOut(nil)
        keyboardHUDPanel?.close()
        keyboardHUDPanel = nil
    }

    // MARK: - Clean Screen Overlays & Pill Proximity

    @discardableResult
    private func showScreenOverlays(animated: Bool) -> CleaningOverlayWindow? {
        closeScreenOverlays()
        let screens = NSScreen.screens
        guard let primaryScreen = NSScreen.main ?? screens.first else { return nil }

        var primaryWindow: CleaningOverlayWindow?
        for screen in screens {
            let isPrimary = screen == primaryScreen
            let window = CleaningOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.allowKeyFocus = isPrimary
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

            if isPrimary {
                window.contentView = FirstMouseHostingView(rootView: CleanScreenOverlayView(service: self))
                primaryWindow = window
            } else {
                window.contentView = FirstMouseHostingView(rootView: CleanScreenSecondaryOverlayView(service: self))
            }

            window.alphaValue = animated ? 0.0 : 1.0
            window.orderFrontRegardless()
            screenOverlayWindows.append(window)
        }

        if let primaryWindow {
            NSApp.activate(ignoringOtherApps: true)
            primaryWindow.makeKeyAndOrderFront(nil)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                for window in screenOverlayWindows {
                    window.animator().alphaValue = 1.0
                }
            }
        }
        return primaryWindow
    }

    private func closeScreenOverlays() {
        for window in screenOverlayWindows {
            window.orderOut(nil)
            window.close()
        }
        screenOverlayWindows.removeAll()
    }

    private func installLocalScreenMonitor() {
        removeLocalEventMonitor()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .keyDown, .keyUp]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let eventType = event.type
            let keyCode = (eventType == .keyDown || eventType == .keyUp) ? Int64(event.keyCode) : -1
            let shouldConsume = MainActor.assumeIsolated {
                guard let self, self.activeMode == .screen else { return false }
                return self.handleLocalScreenEvent(type: eventType, keyCode: keyCode)
            }
            return shouldConsume ? nil : event
        }

        // Fallback global mouse monitor when no Accessibility event tap is installed so cursor
        // unhiding and double-click exit still fire even if another window steals focus.
        if eventTap == nil {
            let globalMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) { [weak self] event in
                let eventType = event.type
                let clickCount = eventType == .leftMouseDown ? event.clickCount : 0
                Task { @MainActor [weak self] in
                    guard let self, self.activeMode == .screen else { return }
                    self.handleScreenMouseProximity(at: NSEvent.mouseLocation)
                    if eventType == .leftMouseDown, clickCount >= 2 {
                        self.stopAll()
                    }
                }
            }
        }
    }

    private func removeLocalEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    private func handleLocalScreenEvent(type: NSEvent.EventType, keyCode: Int64) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown:
            handleScreenMouseProximity(at: NSEvent.mouseLocation)
            return false
        case .keyDown:
            if keyCode == Self.escapeKeyCode {
                revealScreenPillTemporarily()
                beginHoldExit()
            }
            return true
        case .keyUp:
            if keyCode == Self.escapeKeyCode {
                cancelHoldExit()
            }
            return true
        default:
            return false
        }
    }

    private func handleScreenMouseProximity(at point: NSPoint) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let pillZone = NSRect(
            x: frame.midX - 240,
            y: frame.minY,
            width: 480,
            height: 150
        )

        if pillZone.contains(point) {
            isScreenPillRevealed = true
            isHoveringScreenPill = true
            unhideCursorIfNeeded()
            stopScreenPillDimTimer()
        } else {
            isHoveringScreenPill = false
            isScreenPillRevealed = true
            unhideCursorIfNeeded()
            scheduleScreenPillDim()
        }
    }

    private func revealScreenPillTemporarily() {
        isScreenPillRevealed = true
        scheduleScreenPillDim()
    }

    private func scheduleScreenPillDim() {
        stopScreenPillDimTimer()
        screenPillDimTimer = Timer.scheduledTimer(withTimeInterval: Self.screenPillDimDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeMode == .screen else { return }
                if !self.isHoveringScreenPill && self.holdExitStartUptime == nil {
                    self.isScreenPillRevealed = false
                    self.hideCursorIfNeeded()
                }
            }
        }
    }

    private func stopScreenPillDimTimer() {
        screenPillDimTimer?.invalidate()
        screenPillDimTimer = nil
    }
}

// MARK: - CleaningOverlayWindow

/// Borderless fullscreen blackout window; only the primary overlay accepts key focus so
/// clicking a secondary screen never steals key status or halts mouseMoved delivery.
private final class CleaningOverlayWindow: NSWindow {
    var allowKeyFocus = false
    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { allowKeyFocus }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - CleanKeyboardHUDView

private struct CleanKeyboardHUDView: View {
    @ObservedObject var service: CleaningModeService

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.badge.eye")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Keyboard Locked")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if service.interceptedKeyCount > 0 {
                            Text(verbatim: "\(service.interceptedKeyCount)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    Text("Hold ⌘⌥Esc for 1.5s or click Unlock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Unlock Keyboard") {
                    service.stopAll()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if service.exitHoldProgress > 0 {
                ProgressView(value: service.exitHoldProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
        .padding(8)
    }
}

// MARK: - CleanScreenOverlayView

private struct CleanScreenOverlayView: View {
    @ObservedObject var service: CleaningModeService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))

                        Text("Hold Esc (1.5s) or double-click to exit")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))

                        if service.isHoveringScreenPill {
                            Button("Unlock") {
                                service.stopAll()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }

                    if service.exitHoldProgress > 0 {
                        ProgressView(value: service.exitHoldProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 200)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(service.isScreenPillRevealed ? 0.14 : 0.05))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(service.isScreenPillRevealed ? 0.22 : 0.08), lineWidth: 0.5)
                )
                .opacity(service.isScreenPillRevealed ? 1.0 : 0.18)
                .animation(.easeInOut(duration: 0.25), value: service.isScreenPillRevealed)
                .animation(.easeInOut(duration: 0.15), value: service.isHoveringScreenPill)
                .padding(.bottom, 36)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            service.stopAll()
        }
    }
}

// MARK: - CleanScreenSecondaryOverlayView

private struct CleanScreenSecondaryOverlayView: View {
    @ObservedObject var service: CleaningModeService

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                service.stopAll()
            }
    }
}
