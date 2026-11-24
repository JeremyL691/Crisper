import SwiftUI

/// Quick-tools bar at the top of the panel: four equal-width circular toggles
/// for Dark Mode, Power Saving, Clean Keyboard, and Clean Screen.
struct ScreenEffectsView: View {
    var onClosePanel: () -> Void = {}

    @ObservedObject private var effects = CoreBrightnessService.shared
    @ObservedObject private var lowPower = LowPowerModeService.shared
    @ObservedObject private var cleaning = CleaningModeService.shared

    private var activeError: String? {
        if let err = lowPower.lastError, !err.isEmpty { return err }
        if let err = cleaning.lastError, !err.isEmpty { return err }
        return nil
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 2) {
                QuickToolCircleButton(
                    symbol: "circle.lefthalf.filled",
                    label: String(localized: "Dark Mode"),
                    isOn: effects.darkModeEnabled,
                    onFill: .white,
                    onIcon: .black,
                    disabled: !effects.darkModeAvailable
                ) {
                    effects.setDarkMode(!effects.darkModeEnabled)
                }
                .frame(maxWidth: .infinity)

                QuickToolCircleButton(
                    symbol: "battery.25percent",
                    label: String(localized: "Power Saving"),
                    isOn: lowPower.isEnabled,
                    onFill: .orange,
                    onIcon: .white,
                    isBusy: lowPower.isTransitioning,
                    disabled: lowPower.isTransitioning
                ) {
                    lowPower.toggle()
                }
                .frame(maxWidth: .infinity)

                QuickToolCircleButton(
                    symbol: "keyboard",
                    label: String(localized: "Clean Keyboard"),
                    isOn: cleaning.activeMode == .keyboard,
                    onFill: .blue,
                    onIcon: .white
                ) {
                    cleaning.toggleKeyboardCleaning()
                    if cleaning.activeMode != .none {
                        onClosePanel()
                    }
                }
                .frame(maxWidth: .infinity)

                QuickToolCircleButton(
                    symbol: "sparkles.rectangle.stack",
                    label: String(localized: "Clean Screen"),
                    isOn: cleaning.activeMode == .screen,
                    onFill: .indigo,
                    onIcon: .white
                ) {
                    cleaning.toggleScreenCleaning()
                    if cleaning.activeMode != .none {
                        onClosePanel()
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let error = activeError {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onAppear {
            effects.refresh()
            lowPower.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            effects.refresh()
            lowPower.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            cleaning.lastError = nil
            lowPower.lastError = nil
        }
    }
}

/// No press feedback: the dark mode crossfade snapshot freezes anything else
/// mid-flight (reads as a stuck button), and transaction tampering would also
/// strip the panel's layout spring, making the row jump instead of riding
/// section expansions.
private struct InstantPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Circular quick-tool toggle styled like the Control Center display panel:
/// translucent dark circle when off, tinted circle when on.
private struct QuickToolCircleButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    var onFill: Color = .white
    var onIcon: Color = .black
    var isBusy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            guard PanelOpenGuard.allowsActivation, !disabled else { return }
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(onFill) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 36, height: 36)
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isOn ? onIcon : Color.primary.opacity(0.85))
                    }
                }
                VStack(spacing: 1) {
                    Text(verbatim: label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryReadable)
                        .lineLimit(1)
                }
            }
            .opacity(disabled && !isBusy ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstantPressStyle())
        .accessibilityLabel(isOn ? Text("\(label), on") : Text("\(label), off"))
        .accessibilityAddTraits(.isButton)
    }
}
