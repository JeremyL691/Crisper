import XCTest

final class MenuBarAppearanceTests: XCTestCase {
    func testDisplayModeCodableRoundTrip() throws {
        for mode in MenuBarDisplayMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(MenuBarDisplayMode.self, from: encoded)
            XCTAssertEqual(decoded, mode)
        }
        XCTAssertEqual(MenuBarDisplayMode.allCases, [.cpuTemperature, .iconAndTemperature, .iconOnly])
    }

    func testTemperatureStyleCodableRoundTrip() throws {
        for style in MenuBarTemperatureStyle.allCases {
            let encoded = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarTemperatureStyle.self, from: encoded)
            XCTAssertEqual(decoded, style)
        }
        XCTAssertEqual(MenuBarTemperatureStyle.allCases, [.stacked, .verticalTag, .compact])
    }

    func testThermalColorZoneThresholds() {
        XCTAssertEqual(ThermalColorZone.from(celsius: nil), .normal)
        XCTAssertEqual(ThermalColorZone.from(celsius: .nan), .normal)
        XCTAssertEqual(ThermalColorZone.from(celsius: 49.8), .normal)
        XCTAssertEqual(ThermalColorZone.from(celsius: 69.9), .normal)
        XCTAssertEqual(ThermalColorZone.from(celsius: 70.0), .warm)
        XCTAssertEqual(ThermalColorZone.from(celsius: 84.9), .warm)
        XCTAssertEqual(ThermalColorZone.from(celsius: 85.0), .hot)
        XCTAssertEqual(ThermalColorZone.from(celsius: 102.0), .hot)
    }

    func testTemperatureUnitSymbolsAndConversions() throws {
        XCTAssertEqual(TemperatureUnit.celsius.symbol, "°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.symbol, "°F")

        XCTAssertEqual(TemperatureUnit.celsius.convert(celsius: 42.5), 42.5, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(celsius: 0.0), 32.0, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(celsius: 100.0), 212.0, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(celsius: -40.0), -40.0, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(celsius: 37.5), 99.5, accuracy: 0.0001)

        for unit in TemperatureUnit.allCases {
            let data = try JSONEncoder().encode(unit)
            XCTAssertEqual(try JSONDecoder().decode(TemperatureUnit.self, from: data), unit)
        }
    }

    func testSymbolCatalogContainsEightCuratedSymbols() {
        let expected = [
            "sparkles.tv",
            "display",
            "cpu",
            "thermometer.medium",
            "gauge.with.dots.needle.bottom.50percent",
            "macbook",
            "desktopcomputer",
            "bolt.fill"
        ]
        XCTAssertEqual(MenuBarSymbolCatalog.defaultSymbol, "sparkles.tv")
        XCTAssertEqual(MenuBarSymbolCatalog.options.count, 8)
        XCTAssertEqual(MenuBarSymbolCatalog.options.map(\.symbol), expected)
        XCTAssertEqual(MenuBarSymbolCatalog.options.map(\.id), expected)
        XCTAssertTrue(MenuBarSymbolCatalog.isSupported("cpu"))
        XCTAssertFalse(MenuBarSymbolCatalog.isSupported("not.a.symbol"))
        XCTAssertEqual(MenuBarSymbolCatalog.resolved("macbook"), "macbook")
        XCTAssertEqual(MenuBarSymbolCatalog.resolved("unknown.symbol"), MenuBarSymbolCatalog.defaultSymbol)
    }

    func testTemperatureFormatterHandlesMissingAndNonFiniteValues() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity]
        for value in invalid {
            XCTAssertEqual(TemperatureFormatter.format(celsius: value, unit: .celsius, showDecimal: true), "--°C")
            XCTAssertEqual(TemperatureFormatter.format(celsius: value, unit: .celsius, showDecimal: false), "--°C")
            XCTAssertEqual(TemperatureFormatter.format(celsius: value, unit: .fahrenheit, showDecimal: true), "--°F")
            XCTAssertEqual(TemperatureFormatter.format(celsius: value, unit: .fahrenheit, showDecimal: false), "--°F")
        }
    }

    func testTemperatureFormatterFormatsCelsiusAndFahrenheit() {
        XCTAssertEqual(TemperatureFormatter.format(celsius: 49.84, unit: .celsius, showDecimal: true), "49.8°C")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 49.86, unit: .celsius, showDecimal: true), "49.9°C")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 49.8, unit: .celsius, showDecimal: false), "50°C")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 49.4, unit: .celsius, showDecimal: false), "49°C")

        XCTAssertEqual(TemperatureFormatter.format(celsius: 0.0, unit: .fahrenheit, showDecimal: true), "32.0°F")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 0.0, unit: .fahrenheit, showDecimal: false), "32°F")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 100.0, unit: .fahrenheit, showDecimal: true), "212.0°F")
        XCTAssertEqual(TemperatureFormatter.format(celsius: 100.0, unit: .fahrenheit, showDecimal: false), "212°F")

        // Never render negative zero.
        XCTAssertEqual(TemperatureFormatter.format(celsius: -0.04, unit: .celsius, showDecimal: true), "0.0°C")
        XCTAssertEqual(TemperatureFormatter.format(celsius: -0.4, unit: .celsius, showDecimal: false), "0°C")
    }
}
