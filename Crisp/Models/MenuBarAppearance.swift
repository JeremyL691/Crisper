import Foundation

/// How Crisper's main status bar item renders in the macOS menu bar.
enum MenuBarDisplayMode: String, CaseIterable, Codable, Sendable {
    case cpuTemperature
    case iconAndTemperature
    case iconOnly
}

/// Visual layout for the CPU temperature readout in the menu bar.
/// Inspired by open-source macOS monitors `exelban/stats` (Mini / Label) and `eul`.
enum MenuBarTemperatureStyle: String, CaseIterable, Codable, Sendable {
    case stacked      // Compact two-row `CPU` micro-label over temperature (Stats Mini style)
    case verticalTag  // Vertical `C/P/U` micro-tag left of temperature (Stats Label style)
    case compact      // Tight single-line temperature readout (eul / native style)
}

/// Semantic thermal severity bucket used when optional thermal color tinting is enabled.
enum ThermalColorZone: Equatable, Sendable {
    case normal
    case warm
    case hot

    static func from(celsius: Double?) -> ThermalColorZone {
        guard let celsius, celsius.isFinite else { return .normal }
        if celsius >= 85.0 { return .hot }
        if celsius >= 70.0 { return .warm }
        return .normal
    }
}

/// Temperature scale used across the menu bar readout and hardware monitor cards.
enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius
    case fahrenheit

    var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    func convert(celsius: Double) -> Double {
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9.0 / 5.0 + 32.0
        }
    }
}

/// Curated SF Symbols offered for the customizable menu bar icon.
enum MenuBarSymbolCatalog {
    struct Option: Identifiable, Hashable, Sendable {
        let symbol: String
        let label: String
        var id: String { symbol }
    }

    static let defaultSymbol = "sparkles.tv"

    static let options: [Option] = [
        Option(symbol: "sparkles.tv", label: String(localized: "Crisper")),
        Option(symbol: "display", label: String(localized: "Display")),
        Option(symbol: "cpu", label: String(localized: "CPU")),
        Option(symbol: "thermometer.medium", label: String(localized: "Thermometer")),
        Option(symbol: "gauge.with.dots.needle.bottom.50percent", label: String(localized: "Gauge")),
        Option(symbol: "macbook", label: String(localized: "MacBook")),
        Option(symbol: "desktopcomputer", label: String(localized: "Desktop")),
        Option(symbol: "bolt.fill", label: String(localized: "Bolt"))
    ]

    static func isSupported(_ symbol: String) -> Bool {
        options.contains { $0.symbol == symbol }
    }

    static func resolved(_ symbol: String) -> String {
        isSupported(symbol) ? symbol : defaultSymbol
    }
}

/// Deterministic formatting for live hardware temperature strings.
enum TemperatureFormatter {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func format(celsius: Double?, unit: TemperatureUnit, showDecimal: Bool) -> String {
        guard let celsius, celsius.isFinite else {
            return "--\(unit.symbol)"
        }
        let converted = unit.convert(celsius: celsius)
        guard converted.isFinite else {
            return "--\(unit.symbol)"
        }
        if showDecimal {
            let rounded = (converted * 10.0).rounded() / 10.0
            let normalized = rounded == 0.0 ? 0.0 : rounded
            return String(format: "%.1f%@", locale: posixLocale, normalized, unit.symbol)
        } else {
            let rounded = converted.rounded()
            let normalized = rounded == 0.0 ? 0.0 : rounded
            return String(format: "%.0f%@", locale: posixLocale, normalized, unit.symbol)
        }
    }
}
