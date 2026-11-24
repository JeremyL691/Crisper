import Foundation

enum KeepAwakeMode: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case alwaysAwake
    case onACPower

    var id: String { rawValue }
}

struct KeepAwakeConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool = false
    var mode: KeepAwakeMode = .onACPower
}

enum KeepAwakePhase: String, Codable, Equatable, Sendable {
    case disabled
    case suspendedOnBattery
    case active
}

struct KeepAwakeDecision: Equatable, Sendable {
    let phase: KeepAwakePhase
    let shouldHoldAssertion: Bool
}

/// What made Keep Awake re-evaluate. Power-source notifications also fire for every
/// battery percentage or time-remaining change, so they are not a reason to light the display.
enum KeepAwakeEvaluationTrigger: Equatable, Sendable {
    case control
    case powerSourceChange
    case systemWake
}

enum KeepAwakePolicy {
    static func evaluate(
        config: KeepAwakeConfig,
        isOnACPower: Bool,
        isDisabledByPolicy: Bool = false
    ) -> KeepAwakeDecision {
        guard !isDisabledByPolicy, config.isEnabled else {
            return KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false)
        }

        switch config.mode {
        case .alwaysAwake:
            return KeepAwakeDecision(phase: .active, shouldHoldAssertion: true)
        case .onACPower:
            return isOnACPower
                ? KeepAwakeDecision(phase: .active, shouldHoldAssertion: true)
                : KeepAwakeDecision(phase: .suspendedOnBattery, shouldHoldAssertion: false)
        }
    }

    /// Declares user activity (which powers the display on) only when assertions come back
    /// after a battery suspension, or on a system wake while on AC.
    static func shouldDeclareUserActivity(
        previousPhase: KeepAwakePhase,
        decision: KeepAwakeDecision,
        isOnACPower: Bool,
        trigger: KeepAwakeEvaluationTrigger
    ) -> Bool {
        guard decision.shouldHoldAssertion, decision.phase == .active else { return false }
        if previousPhase == .suspendedOnBattery { return true }
        return trigger == .systemWake && isOnACPower
    }
}
