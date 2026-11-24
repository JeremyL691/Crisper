import SwiftUI
import AppKit

/// Per-display "Extra Brightness" toggle: unlocks the brightness slider beyond
/// 100% by engaging the EDR upscaling overlay. Rendered only for displays that
/// can actually boost (built-in XDR panels, HDR-capable externals). For an
/// external in SDR mode, enabling also switches the monitor into HDR mode.
struct ExtraBrightnessView: View {
    @ObservedObject var display: DisplayInfo
    /// Plain form switch for Advanced Settings instead of the panel row.
    var inForm = false
    @State private var isOn: Bool = false
    @State private var request: UUID?

    var body: some View {
        if BrightnessBoostService.shared.isEligible(display) {
            SettingSwitchRow(inForm: inForm, icon: "sun.max.fill", color: .yellow,
                             label: "Extra Brightness", isOn: Binding(get: { isOn }, set: { newValue in
                isOn = newValue
                let token = UUID()
                request = token
                Task { @MainActor in
                    guard request == token else { return }
                    _ = await BrightnessBoostService.shared.setEnabled(newValue, for: display)
                    if request == token {
                        request = nil
                        isOn = BrightnessBoostService.shared.isEnabled(for: display)
                    }
                }
            }))
            .onAppear {
                syncIfIdle()
            }
            // The service can silently disable boost (BrightnessBoostService.headroomLossPolls).
            // Re-read on every panel open so the toggle doesn't go stale.
            .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
                syncIfIdle()
            }
            // Catches the same auto-disable while the panel stays open, once
            // maxBrightness collapses back to 100.
            .onChange(of: display.maxBrightness) { _, newValue in
                if newValue <= 100.5 { syncIfIdle() }
            }
        }
    }

    private func syncIfIdle() {
        guard request == nil else { return }
        isOn = BrightnessBoostService.shared.isEnabled(for: display)
    }
}
