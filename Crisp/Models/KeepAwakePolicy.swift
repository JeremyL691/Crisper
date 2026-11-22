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
}
