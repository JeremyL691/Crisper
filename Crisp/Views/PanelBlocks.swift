import SwiftUI
import AppKit

// The panel's content, decomposed into split-canvas blocks: each block renders
// once at its natural size, and AppKit animates the clips and window instead
// of SwiftUI. See docs/panel-resize.md for the full architecture.

/// Section open/close state, lifted out of the view tree so both the SwiftUI
/// headers (chevrons, bindings) and the AppKit canvas (clip targets) share it.
@MainActor
final class PanelSectionState: ObservableObject {
    @Published var showKeepAwakeModes = false
    @Published var showSettings = false
    @Published var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    // Per-display dropdown sections, lifted out of view @State so each reveal
    // is its own canvas block (docs/panel-resize.md).
    @Published var resolutionOpenIDs: Set<CGDirectDisplayID> = []
    @Published var allResolutionsOpenIDs: Set<CGDirectDisplayID> = []
    @Published var refreshOpenIDs: Set<CGDirectDisplayID> = []
    @Published var rotationOpenIDs: Set<CGDirectDisplayID> = []
    @Published var profileOpenIDs: Set<CGDirectDisplayID> = []
    @Published var imageOpenIDs: Set<CGDirectDisplayID> = []
    @Published var inputOpenIDs: Set<CGDirectDisplayID> = []

    /// Collapse every section so the panel reopens fresh; called once hidden.
    func collapseAll() {
        showKeepAwakeModes = false
        showSettings = false
        expandedDisplayIDs.removeAll()
        resolutionOpenIDs.removeAll()
        allResolutionsOpenIDs.removeAll()
        refreshOpenIDs.removeAll()
        rotationOpenIDs.removeAll()
        profileOpenIDs.removeAll()
        imageOpenIDs.removeAll()
        inputOpenIDs.removeAll()
    }

    /// Drop state for displays that disappeared (disconnect, reconfiguration).
    func retainDisplays(_ valid: Set<CGDirectDisplayID>) {
        expandedDisplayIDs.formIntersection(valid)
        resolutionOpenIDs.formIntersection(valid)
        allResolutionsOpenIDs.formIntersection(valid)
        refreshOpenIDs.formIntersection(valid)
        rotationOpenIDs.formIntersection(valid)
        profileOpenIDs.formIntersection(valid)
        imageOpenIDs.formIntersection(valid)
        inputOpenIDs.formIntersection(valid)
    }

    /// Binding into one of the per-display sets, for ExpandableRow chevrons.
    func openBinding(
        _ keyPath: ReferenceWritableKeyPath<PanelSectionState, Set<CGDirectDisplayID>>,
        _ id: CGDirectDisplayID
    ) -> Binding<Bool> {
        Binding(
            get: { self[keyPath: keyPath].contains(id) },
            set: {
                if $0 { self[keyPath: keyPath].insert(id) } else { self[keyPath: keyPath].remove(id) }
            }
        )
    }
}

/// Wraps a block's content with the fixed panel width, natural-height sizing,
/// and the height reporter feeding the canvas.
struct BlockHost<Content: View>: View {
    let onHeight: (CGFloat) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        // Report natural height; the canvas springs the clip to it.
        content
            .frame(width: 308)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            // Top-glue: pin to .top so NSHostingView doesn't center a nested
            // curtain's shorter mid-reveal content (that drifts the top row).
            // Do not add .fixedSize: it defeats this fill.
            // Measured: see docs/ui-notes.md (PanelBlocks: BlockHost top-glue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// An ExpandableRow bound to a PanelSectionState flag; observes the state so
/// the chevron re-renders when the flag flips.
struct ExpandableRowStateful: View {
    let icon: String
    var iconColor: Color = .blue
    var iconActive: Bool = true
    let label: String
    @ObservedObject var state: PanelSectionState
    let key: ReferenceWritableKeyPath<PanelSectionState, Bool>

    var body: some View {
        ExpandableRow(
            icon: icon,
            iconColor: iconColor,
            iconActive: iconActive,
            label: label,
            isExpanded: Binding(
                get: { state[keyPath: key] },
                set: { state[keyPath: key] = $0 }
            )
        )
    }
}

/// Display name row + inline brightness slider (the always-visible part of a
/// display section).
struct DisplayHeaderBlock: View {
    @ObservedObject var display: DisplayInfo
    let isFirst: Bool
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 0) {
            DisplayRowView(
                display: display,
                isExpanded: state.expandedDisplayIDs.contains(display.displayID),
                onToggleExpand: {
                    withAnimation(.panelResize) {
                        if state.expandedDisplayIDs.contains(display.displayID) {
                            state.expandedDisplayIDs.remove(display.displayID)
                        } else {
                            state.expandedDisplayIDs.insert(display.displayID)
                        }
                    }
                }
            )
            BrightnessSliderView(display: display, compact: true)
                .padding(.bottom, 4)

            // Speaker volume: shown only when DDC volume answered (#23) and
            // the setting is on; height changes flow through BlockHost.
            if settings.showVolumeSliders && display.volumeSupported {
                VolumeSliderView(display: display)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, isFirst ? 0 : 8)
    }
}

/// Keep Awake: hold a power assertion against idle-sleep in Always Awake or On AC Power mode.
/// The switch toggles Keep Awake on/off; tapping the row opens the mode selector.
struct KeepAwakeRow: View {
    @ObservedObject private var keepAwake = KeepAwakeService.shared
    @ObservedObject var state: PanelSectionState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "cup.and.saucer.fill", color: .orange, active: keepAwake.isActive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake")
                    .font(.body)
                    .lineLimit(1)
                subtitle
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(state.showKeepAwakeModes ? 90 : 0))
                .accessibilityHidden(true)
            Toggle("Keep Awake", isOn: Binding(
                get: { keepAwake.isEnabled },
                set: { on in
                    withAnimation(.panelResize) {
                        keepAwake.setEnabled(on)
                        if !on { state.showKeepAwakeModes = false }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            withAnimation(.panelResize) { state.showKeepAwakeModes.toggle() }
        }
        .onHover { isHovered = $0 }
    }

    private var subtitle: Text {
        switch (keepAwake.phase, keepAwake.mode) {
        case (.active, .alwaysAwake):
            return Text("Always Awake")
        case (.active, .onACPower):
            return Text("Active · On AC Power")
        case (.suspendedOnBattery, _):
            return Text("Paused on battery · Resumes on AC")
        case (.disabled, .onACPower):
            return Text("Off · On AC Power")
        case (.disabled, .alwaysAwake):
            return Text("Off · Always Awake")
        }
    }
}

/// Mode picker under Keep Awake. Selecting a mode applies it and collapses the drawer.
struct KeepAwakeModesBlock: View {
    @ObservedObject private var keepAwake = KeepAwakeService.shared
    @ObservedObject var state: PanelSectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeepAwakeModeRow(
                title: "Always Awake",
                description: "Stay awake on AC and battery",
                isSelected: keepAwake.mode == .alwaysAwake
            ) {
                select(.alwaysAwake)
            }
            KeepAwakeModeRow(
                title: "On AC Power",
                description: "Pause on battery · Resume immediately on AC",
                isSelected: keepAwake.mode == .onACPower
            ) {
                select(.onACPower)
            }
        }
        .padding(.bottom, 2)
    }

    private func select(_ mode: KeepAwakeMode) {
        guard PanelOpenGuard.allowsActivation else { return }
        withAnimation(.panelResize) {
            keepAwake.selectMode(mode)
            state.showKeepAwakeModes = false
        }
    }
}

private struct KeepAwakeModeRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Saved and off by default, unlike Keep Awake; see EdgeCrossingService. Hidden with one
/// display, which has no shared edge.
struct EdgeCrossingRow: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject private var displayManager: DisplayManager

    var body: some View {
        if displayManager.displays.count > 1 {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: $settings.crossDisplayGaps) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "cursorarrow.motionlines", color: .purple, active: settings.crossDisplayGaps)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cross Unaligned Edges")
                        .font(.body)
                    Text("The pointer jumps to the nearest display where edges don't line up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

/// Update notice; renders nothing until an update is known, so it glides in.
struct UpdateBlockView: View {
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        if updateService.hasUpdate, let ver = updateService.latestVersion {
            UpdateRow(version: ver) { updateService.installUpdate() }
        }
    }
}

/// Fixed footer: divider + Quit, like the Wi-Fi menu's settings footer.
struct PanelFooterBlock: View {
    @State private var quitHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25).padding(.horizontal, 12)
            HStack {
                Text("Quit Crisper")
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(quitHovered)
            .contentShape(Rectangle())
            .onTapGesture {
                NSApplication.shared.terminate(nil)
            }
            .onHover { quitHovered = $0 }
            .padding(.top, 4)
        }
        .padding(.bottom, 8)
    }
}
