import AppKit
import SwiftUI

/// 2×2 hardware monitor cards (CPU, GPU, Disk, RAM) rendered directly in the menu bar panel.
/// Uses explicit VStack/HStack rows (never LazyVGrid) so split-canvas animations stay rock-solid.
struct SystemMonitorView: View {
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var monitor = SystemMonitorService.shared
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                CPUMonitorCard(
                    modelName: monitor.cpuModelName,
                    sample: monitor.cpuSample,
                    history: monitor.cpuHistory,
                    temperatureText: TemperatureFormatter.format(
                        celsius: monitor.cpuTemperatureC,
                        unit: settings.temperatureUnit,
                        showDecimal: settings.showTemperatureDecimal
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                GPUMonitorCard(
                    modelName: monitor.gpuModelName,
                    coreCount: monitor.gpuCoreCount,
                    sample: monitor.gpuSample,
                    history: monitor.gpuHistory
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                DiskMonitorCard(
                    disk: monitor.disk,
                    temperatureText: monitor.disk.temperatureC.map {
                        TemperatureFormatter.format(
                            celsius: $0,
                            unit: settings.temperatureUnit,
                            showDecimal: settings.showTemperatureDecimal
                        )
                    },
                    isDetailOpen: state.showDiskDetail,
                    onToggleDetail: {
                        guard PanelOpenGuard.allowsActivation else { return }
                        let opening = !state.showDiskDetail
                        if opening {
                            monitor.refreshDiskVolumes()
                        }
                        withAnimation(.panelResize) {
                            state.showDiskDetail.toggle()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                RAMMonitorCard(
                    ram: monitor.ram,
                    isFreeingMemory: monitor.isFreeingMemory,
                    feedback: monitor.freeMemoryFeedback,
                    onFreeUp: {
                        guard PanelOpenGuard.allowsActivation else { return }
                        monitor.freeUpMemory()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - CPU Card

private struct CPUMonitorCard: View {
    let modelName: String
    let sample: CPUSample
    let history: [CPUSample]
    let temperatureText: String

    private var chartLayers: [StackedAreaLayer] {
        [
            StackedAreaLayer(color: .blue, values: history.map(\.user)),
            StackedAreaLayer(color: .red, values: history.map(\.system))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryReadable)
                Text(verbatim: "CPU")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
            }

            HStack(spacing: 4) {
                Text(verbatim: modelName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryReadable)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Text(verbatim: temperatureText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            StackedAreaChart(layers: chartLayers, maxSamples: 32, baseCeiling: 100)
                .frame(height: 40)

            VStack(spacing: 2) {
                MetricLegendRow(swatch: .blue, label: "User", value: formatPercent(sample.user))
                MetricLegendRow(swatch: .red, label: "System", value: formatPercent(sample.system))
                MetricLegendRow(swatch: .clear, label: "Idle", value: formatPercent(sample.idle))
            }
        }
        .monitorCardSurface()
    }
}

// MARK: - GPU Card

private struct GPUMonitorCard: View {
    let modelName: String
    let coreCount: Int
    let sample: GPUSample
    let history: [GPUSample]

    private static let gpuSymbol: String = {
        NSImage(systemSymbolName: "gpu", accessibilityDescription: nil) != nil ? "gpu" : "memorychip"
    }()

    private var chartLayers: [StackedAreaLayer] {
        [
            StackedAreaLayer(color: .blue, values: history.map(\.device)),
            StackedAreaLayer(color: .red, values: history.map(\.render)),
            StackedAreaLayer(color: .teal, values: history.map(\.tiler))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: Self.gpuSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryReadable)
                Text(verbatim: "GPU")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
            }

            HStack(spacing: 4) {
                Text(verbatim: modelName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryReadable)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if coreCount > 0 {
                    Text(verbatim: "\(coreCount) Core")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondaryReadable)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            StackedAreaChart(layers: chartLayers, maxSamples: 32, baseCeiling: 100)
                .frame(height: 40)

            VStack(spacing: 2) {
                MetricLegendRow(swatch: .blue, label: "Device", value: formatPercent(sample.device))
                MetricLegendRow(swatch: .red, label: "Render", value: formatPercent(sample.render))
                MetricLegendRow(swatch: .teal, label: "Tiler", value: formatPercent(sample.tiler))
            }
        }
        .monitorCardSurface()
    }
}

// MARK: - Disk Card

private struct DiskMonitorCard: View {
    let disk: DiskSnapshot
    let temperatureText: String?
    let isDetailOpen: Bool
    let onToggleDetail: () -> Void
    @State private var detailHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryReadable)
                Text(verbatim: disk.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if let temperatureText {
                    Text(verbatim: temperatureText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            HStack(spacing: 4) {
                Text(verbatim: "F: \(ByteRateFormatter.formatDecimalGB(disk.availableBytes))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(verbatim: "T: \(ByteRateFormatter.formatDecimalGB(disk.totalBytes))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Color.secondaryReadable)
            .monospacedDigit()

            CapsuleProgressBar(fraction: disk.usedFraction, tint: .blue, height: 6)

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "R: \(ByteRateFormatter.formatSpeed(disk.readBytesPerSec))")
                    Text(verbatim: "W: \(ByteRateFormatter.formatSpeed(disk.writeBytesPerSec))")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondaryReadable)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Spacer(minLength: 2)

                Button(action: onToggleDetail) {
                    HStack(spacing: 2) {
                        Text("Detail")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .rotationEffect(.degrees(isDetailOpen ? 90 : 0))
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.blue.opacity(detailHovered ? 0.14 : 0))
                    )
                }
                .fixedSize()
                .buttonStyle(.plain)
                .onHover { detailHovered = $0 }
                .accessibilityAddTraits(.isButton)
            }
        }
        .monitorCardSurface()
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            detailHovered = false
        }
    }
}

// MARK: - RAM Card

private struct RAMMonitorCard: View {
    let ram: RAMSnapshot
    let isFreeingMemory: Bool
    let feedback: String?
    let onFreeUp: () -> Void
    @State private var freeUpHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryReadable)
                Text(verbatim: "RAM")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
            }

            HStack(spacing: 4) {
                Text(verbatim: "U: \(ByteRateFormatter.formatBinaryGB(ram.usedBytes))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(verbatim: "T: \(ByteRateFormatter.formatBinaryGB(ram.totalBytes))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Color.secondaryReadable)
            .monospacedDigit()

            CapsuleProgressBar(fraction: ram.usedFraction, tint: .blue, height: 6)

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 4) {
                if let feedback, !feedback.isEmpty {
                    Text(verbatim: feedback)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryReadable)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 2)

                if isFreeingMemory {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(height: 16)
                } else {
                    Button(action: onFreeUp) {
                        Text("Free Up")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.blue.opacity(freeUpHovered ? 0.14 : 0))
                            )
                    }
                    .fixedSize()
                    .buttonStyle(.plain)
                    .onHover { freeUpHovered = $0 }
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .monitorCardSurface()
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            freeUpHovered = false
        }
    }
}

// MARK: - Expandable Disk Detail Block

/// Expandable volume breakdown shown below the 2×2 system monitor grid when Disk "Detail" is open.
struct DiskDetailBlock: View {
    var onClosePanel: () -> Void = {}
    @ObservedObject private var monitor = SystemMonitorService.shared
    @State private var storageLinkHovered = false

    private static let storageSettingsURL = "x-apple.systempreferences:com.apple.settings.Storage"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage Volumes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryReadable)
                Spacer()
                Button {
                    guard PanelOpenGuard.allowsActivation,
                          let url = URL(string: Self.storageSettingsURL) else { return }
                    onClosePanel()
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 3) {
                        Text("Open Storage Settings")
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.blue.opacity(storageLinkHovered ? 0.14 : 0))
                    )
                }
                .buttonStyle(.plain)
                .onHover { storageLinkHovered = $0 }
            }

            if monitor.disk.volumes.isEmpty {
                Text("No mounted volumes")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryReadable)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(monitor.disk.volumes) { volume in
                        VolumeDetailRow(volume: volume)
                    }
                }
            }
        }
        .monitorCardSurface()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            storageLinkHovered = false
        }
    }
}

private struct VolumeDetailRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondaryReadable)
                Text(verbatim: volume.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(volume.isInternal ? "Internal" : "External")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(volume.isInternal ? Color.blue : Color.teal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill((volume.isInternal ? Color.blue : Color.teal).opacity(0.14))
                    )
                Spacer(minLength: 4)
                if !volume.fileSystem.isEmpty {
                    Text(verbatim: volume.fileSystem)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryReadable)
                        .lineLimit(1)
                }
            }

            CapsuleProgressBar(
                fraction: volume.usedFraction,
                tint: volume.isInternal ? .blue : .teal,
                height: 5
            )

            HStack {
                let availableText = ByteRateFormatter.formatDecimalGB(volume.availableBytes)
                let totalText = ByteRateFormatter.formatDecimalGB(volume.totalBytes)
                Text("\(availableText) free / \(totalText)")
                Spacer()
                Text(verbatim: formatPercent(volume.usedFraction * 100))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Color.secondaryReadable)
            .monospacedDigit()
        }
    }
}

// MARK: - Chart & Shared Primitives

private struct StackedAreaLayer {
    let color: Color
    let values: [Double]
}

/// Lightweight SwiftUI Canvas stacked area chart for 32-point telemetry ring buffers.
private struct StackedAreaChart: View {
    let layers: [StackedAreaLayer]
    let maxSamples: Int
    let baseCeiling: Double

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let bgPath = Path(roundedRect: rect, cornerRadius: 5, style: .continuous)
            context.fill(bgPath, with: .color(Color.primary.opacity(0.05)))

            let sampleCount = layers.map(\.values.count).max() ?? 0
            guard sampleCount > 0, size.width > 1, size.height > 1 else { return }

            let slots = max(2, maxSamples)
            let stepX = size.width / CGFloat(slots - 1)
            let startSlot = max(0, slots - sampleCount)

            var stackedTotals = [Double](repeating: 0, count: sampleCount)
            var peak = baseCeiling
            for layer in layers {
                for idx in 0..<sampleCount {
                    let val = idx < layer.values.count ? max(0, layer.values[idx]) : 0
                    stackedTotals[idx] += val
                    if stackedTotals[idx] > peak { peak = stackedTotals[idx] }
                }
            }
            let metrics = ChartMetrics(
                size: size,
                ceiling: max(1, peak),
                startSlot: startSlot,
                stepX: stepX
            )

            var baselines = [Double](repeating: 0, count: sampleCount)
            for layer in layers {
                var tops = [Double](repeating: 0, count: sampleCount)
                for idx in 0..<sampleCount {
                    let val = idx < layer.values.count ? max(0, layer.values[idx]) : 0
                    tops[idx] = min(metrics.ceiling, baselines[idx] + val)
                }

                drawLayer(
                    in: &context,
                    metrics: metrics,
                    color: layer.color,
                    baselines: baselines,
                    tops: tops
                )
                baselines = tops
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }

    private struct ChartMetrics {
        let size: CGSize
        let ceiling: Double
        let startSlot: Int
        let stepX: CGFloat

        func point(index: Int, count: Int, value: Double) -> CGPoint {
            let x = count == 1 ? size.width - 1 : CGFloat(startSlot + index) * stepX
            let normalized = CGFloat(value / ceiling)
            let y = size.height - 1 - normalized * (size.height - 2)
            return CGPoint(x: x, y: min(size.height - 1, max(1, y)))
        }
    }

    private func drawLayer(
        in context: inout GraphicsContext,
        metrics: ChartMetrics,
        color: Color,
        baselines: [Double],
        tops: [Double]
    ) {
        let count = tops.count
        guard count > 0 else { return }

        let topPoints = (0..<count).map { metrics.point(index: $0, count: count, value: tops[$0]) }
        let basePoints = (0..<count).map { metrics.point(index: $0, count: count, value: baselines[$0]) }

        guard count > 1 else {
            let dot = CGRect(x: topPoints[0].x - 1.5, y: topPoints[0].y - 1.25, width: 2.5, height: 2.5)
            context.fill(Path(ellipseIn: dot), with: .color(color))
            return
        }

        var fillPath = Path()
        fillPath.move(to: topPoints[0])
        for point in topPoints.dropFirst() {
            fillPath.addLine(to: point)
        }
        for point in basePoints.reversed() {
            fillPath.addLine(to: point)
        }
        fillPath.closeSubpath()

        var strokePath = Path()
        strokePath.move(to: topPoints[0])
        for point in topPoints.dropFirst() {
            strokePath.addLine(to: point)
        }

        context.fill(fillPath, with: .color(color.opacity(0.28)))
        context.stroke(
            strokePath,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        )
    }
}

private struct MetricLegendRow: View {
    let swatch: Color
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(swatch)
                .frame(width: 6, height: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .strokeBorder(
                            swatch == .clear ? Color.primary.opacity(0.18) : Color.clear,
                            lineWidth: 0.5
                        )
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryReadable)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct CapsuleProgressBar: View {
    let fraction: Double
    let tint: Color
    let height: CGFloat

    private var clamped: CGFloat {
        guard fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(clamped > 0 ? height : 0, geo.size.width * clamped))
                    .animation(.easeOut(duration: 0.25), value: clamped)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct MonitorCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.065))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
    }
}

private extension View {
    func monitorCardSurface() -> some View {
        modifier(MonitorCardSurface())
    }
}

private func formatPercent(_ value: Double) -> String {
    let safe = value.isFinite ? min(100, max(0, value)) : 0
    return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), safe)
}
