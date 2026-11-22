import SwiftUI

/// Menu bar Smart Dummy row: single master switch with live state subtitle.
struct VirtualDisplayView: View {
    @ObservedObject private var service = VirtualDisplayService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MenuItemIcon(
                    systemName: "display.2",
                    color: iconColor,
                    active: service.phase != .disabled
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smart Dummy")
                        .font(.body)
                        .lineLimit(1)
                    statusSubtitle
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                if service.isTransitioning {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { service.smartConfig.isEnabled },
                        set: { on in
                            Task { @MainActor in
                                _ = await service.setSmartDummyEnabled(on)
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Smart Dummy")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            if let error = service.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    private var iconColor: Color {
        switch service.phase {
        case .activeMounted:
            return .blue
        case .armedStandby:
            return .teal
        case .suspendedOnBattery:
            return .orange
        case .disabled:
            return .blue
        }
    }

    private var statusSubtitle: Text {
        switch service.phase {
        case .activeMounted:
            return Text("Active · \(VirtualDisplayService.smartSummary(service.smartConfig))")
        case .armedStandby:
            return Text("Standby · Physical display in use")
        case .suspendedOnBattery:
            return Text("Paused on battery · Resumes on AC")
        case .disabled:
            return Text("Off · AC auto-enable")
        }
    }
}

// MARK: - Advanced Settings tab

/// Advanced Settings > Smart Dummy: single-dummy configuration, clamshell guard, and live
/// runtime state. Changes apply immediately via `VirtualDisplayService.updateSmartConfig`.
struct AdvancedVirtualDisplaysTab: View {
    @ObservedObject private var service = VirtualDisplayService.shared
    @State private var name: String = VirtualDisplayService.shared.smartConfig.name
    @State private var isCustomSize: Bool = !Self.isPresetSize(
        width: VirtualDisplayService.shared.smartConfig.width,
        height: VirtualDisplayService.shared.smartConfig.height
    )
    @State private var customWidth: String = String(VirtualDisplayService.shared.smartConfig.width)
    @State private var customHeight: String = String(VirtualDisplayService.shared.smartConfig.height)

    struct ResolutionPreset {
        let label: String
        let width: Int
        let height: Int
        let defaultHiDPI: Bool
    }

    static let sizes: [ResolutionPreset] = [
        ResolutionPreset(label: "1600×1000 HiDPI (3200×2000)", width: 3200, height: 2000, defaultHiDPI: true),
        ResolutionPreset(label: "1920×1080", width: 1920, height: 1080, defaultHiDPI: false),
        ResolutionPreset(label: "2560×1440", width: 2560, height: 1440, defaultHiDPI: false),
        ResolutionPreset(label: "3840×2160", width: 3840, height: 2160, defaultHiDPI: false)
    ]

    private static func isPresetSize(width: Int, height: Int) -> Bool {
        sizes.contains { $0.width == width && $0.height == height }
    }

    var body: some View {
        let config = service.smartConfig
        Form {
            Section("Smart Dummy") {
                CenteredRow(
                    title: "Enable Smart Dummy",
                    // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                    detail: Text("Automatically mounts when no physical display is in use and yields when one connects. Active on AC power only; pauses on battery and resumes when plugged back in.")
                ) {
                    Toggle("Enable Smart Dummy", isOn: Binding(
                        get: { config.isEnabled },
                        set: { on in
                            Task { @MainActor in
                                _ = await service.setSmartDummyEnabled(on)
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(service.isTransitioning)
                }

                CenteredRow(
                    title: "Clamshell Stay-Awake Guard",
                    detail: Text("Prevents lid-closed sleep and screen lock when unplugging external monitors on AC power.")
                ) {
                    Toggle("Clamshell Stay-Awake Guard", isOn: Binding(
                        get: { config.clamshellGuardEnabled },
                        set: { on in
                            Task { @MainActor in
                                _ = await service.updateSmartConfig { $0.clamshellGuardEnabled = on }
                            }
                        }
                    ))
                    .labelsHidden()
                }

                if let error = service.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Display Configuration") {
                TextField("Name", text: $name)
                    .onSubmit { commitName() }

                Picker("Resolution", selection: Binding(
                    get: { isCustomSize ? -1 : sizeIndex },
                    set: { index in
                        if index < 0 {
                            isCustomSize = true
                            customWidth = String(config.width)
                            customHeight = String(config.height)
                        } else {
                            isCustomSize = false
                            let preset = Self.sizes[index]
                            customWidth = String(preset.width)
                            customHeight = String(preset.height)
                            Task { @MainActor in
                                _ = await service.updateSmartConfig {
                                    $0.width = preset.width
                                    $0.height = preset.height
                                    $0.hiDPI = preset.defaultHiDPI
                                    $0.startsHiDPI = preset.defaultHiDPI
                                }
                            }
                        }
                    }
                )) {
                    ForEach(Self.sizes.indices, id: \.self) { i in
                        Text(verbatim: Self.sizes[i].label).tag(i)
                    }
                    Text("Custom…").tag(-1)
                }

                if isCustomSize {
                    LabeledContent("Custom…") {
                        HStack(spacing: 6) {
                            TextField("Width", text: $customWidth).frame(width: 64)
                            Text(verbatim: "×").foregroundStyle(.secondary)
                            TextField("Height", text: $customHeight).frame(width: 64)
                            if let valid = parsedCustomSize,
                               valid.width != config.width || valid.height != config.height {
                                Button("Apply") { commitCustomSize() }
                                    .controlSize(.small)
                            }
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitCustomSize() }
                    }
                    if parsedCustomSize == nil {
                        Text("Width must be 640–8192 and height 480–8192.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Picker("Refresh Rate", selection: Binding(
                    get: { config.refreshRate },
                    set: { rate in
                        Task { @MainActor in
                            _ = await service.updateSmartConfig { $0.refreshRate = rate }
                        }
                    }
                )) {
                    ForEach(rateOptions, id: \.self) {
                        Text(verbatim: RefreshRateFormat.label($0)).tag($0)
                    }
                }

                // The 2x mode needs an even width and height.
                Toggle("Start in HiDPI", isOn: Binding(
                    get: { config.effectiveStartsHiDPI },
                    set: { on in
                        Task { @MainActor in
                            _ = await service.updateSmartConfig {
                                $0.startsHiDPI = on
                                if on { $0.hiDPI = true }
                            }
                        }
                    }
                ))
                .disabled(!config.width.isMultiple(of: 2) || !config.height.isMultiple(of: 2))
            }

            Section("Live Status") {
                LabeledContent("State", value: phaseLabel)
                LabeledContent("Power", value: service.liveInput.isOnACPower
                    ? String(localized: "AC Power")
                    : String(localized: "Battery"))
                LabeledContent("Lid", value: service.liveInput.isClamshellClosed
                    ? String(localized: "Closed")
                    : String(localized: "Open"))
                LabeledContent("Active Physical Displays", value: physicalDisplayCountLabel)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: .infinity)
        .onDisappear { commitName() }
        .onChange(of: service.smartConfig.name) { _, updated in
            if name != updated { name = updated }
        }
        .onChange(of: service.smartConfig.width) { _, newWidth in
            customWidth = String(newWidth)
            isCustomSize = !Self.isPresetSize(width: newWidth, height: service.smartConfig.height)
        }
        .onChange(of: service.smartConfig.height) { _, newHeight in
            customHeight = String(newHeight)
            isCustomSize = !Self.isPresetSize(width: service.smartConfig.width, height: newHeight)
        }
    }

    private var sizeIndex: Int {
        Self.sizes.firstIndex {
            $0.width == service.smartConfig.width && $0.height == service.smartConfig.height
        } ?? -1
    }

    private var rateOptions: [Double] {
        let options = VirtualDisplayService.refreshRateOptions
        let current = service.smartConfig.refreshRate
        return options.contains(current) ? options : (options + [current]).sorted()
    }

    private var parsedCustomSize: (width: Int, height: Int)? {
        guard let width = Int(customWidth), let height = Int(customHeight),
              (640...8192).contains(width), (480...8192).contains(height) else { return nil }
        return (width, height)
    }

    private var phaseLabel: String {
        switch service.phase {
        case .activeMounted:
            return String(localized: "Active")
        case .armedStandby:
            return String(localized: "Standby")
        case .suspendedOnBattery:
            return String(localized: "Paused on battery")
        case .disabled:
            return String(localized: "Off")
        }
    }

    private var physicalDisplayCountLabel: String {
        let external = service.liveInput.activePhysicalExternalCount
        let builtin = service.liveInput.activeBuiltinCount
        let total = external + builtin
        return String(localized: "\(total) (\(external) external, \(builtin) built-in)")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != service.smartConfig.name else { return }
        Task { @MainActor in
            _ = await service.updateSmartConfig { $0.name = trimmed }
        }
    }

    private func commitCustomSize() {
        guard let size = parsedCustomSize else { return }
        Task { @MainActor in
            _ = await service.updateSmartConfig {
                $0.width = size.width
                $0.height = size.height
                if !size.width.isMultiple(of: 2) || !size.height.isMultiple(of: 2) {
                    $0.hiDPI = false
                    $0.startsHiDPI = false
                }
            }
        }
    }
}
