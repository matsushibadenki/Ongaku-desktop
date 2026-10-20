/* Hallmark · pre-emit critique: P5 H4 E4 S5 R4 V3
 * component: effects rack · genre: atmospheric · macrostructure: Workbench extension
 * theme: Midnight · hierarchy: tab > module > parameters
 * density: compact desktop workbench · grid: adaptive
 */
import SwiftUI

struct EffectsRackView: View {
    @EnvironmentObject private var player: PlaybackController
    @Binding var selectedTab: AudioEffectPageTab
    @StateObject private var input = EffectRackInputRouter()

    private var visibleKinds: [RealtimeAudioEffectKind] {
        let allowed = AudioEffectModuleRegistry.activeKinds(for: selectedTab)
        return AudioEffectModuleRegistry.activeKinds.filter(allowed.contains)
    }

    private var countSummary: AudioEffectCountSummary {
        player.effectCountSummary(for: selectedTab)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                rackToolbar

                if selectedTab == .off {
                    bypassPanel
                } else {
                    MasonryEffectLayout(
                        minimumColumnWidth: 330,
                        maximumColumnWidth: 520,
                        spacing: AppTheme.spaceMD
                    ) {
                        ForEach(visibleKinds) { kind in
                            EffectModuleCard(kind: kind)
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.spaceLG)
            .padding(
                .bottom,
                selectedTab == .pro ? AppTheme.bottomPlayerClearance : AppTheme.spaceLG
            )
            .effectRackViewport(input)
        }
        .environmentObject(input)
        .onAppear {
            selectedTab = player.effectsBypassed ? .off : .basic
        }
        .onChange(of: selectedTab) { _, newValue in
            player.setEffectsBypassed(newValue == .off)
        }
    }

    private var rackToolbar: some View {
        HStack(spacing: AppTheme.spaceMD) {
            // A segmented Picker's native label can change its wrapping height
            // during updates. Lay out the title separately from the native control.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.text("effects.mode"))
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .foregroundStyle(AppTheme.secondaryInk)
                        .help(explanation)
                        .accessibilityLabel(explanation)
                }
                .fixedSize()

                Picker(L10n.text("effects.mode"), selection: Binding(
                    get: { selectedTab },
                    set: { if !input.isScrolling { selectedTab = $0 } }
                )) {
                    ForEach(AudioEffectPageTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .fixedSize(horizontal: false, vertical: true)
                .effectRackControl()
            }
            .fixedSize()

            Spacer(minLength: AppTheme.spaceMD)

            Label(
                L10n.format("effects.enabledShort", countSummary.enabled),
                systemImage: "waveform.path.ecg"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(countSummary.enabled > 0 ? AppTheme.good : AppTheme.secondaryInk)
            .lineLimit(1)
            .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppTheme.spaceMD)
        .ongakuPanel()
    }

    private var explanation: String {
        switch selectedTab {
        case .basic: L10n.text("effects.basicExplanation")
        case .pro: L10n.text("effects.proExplanation")
        case .off: L10n.text("effects.offExplanation")
        }
    }

    private var bypassPanel: some View {
        VStack(spacing: AppTheme.spaceMD) {
            Image(systemName: "power")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppTheme.secondaryInk)
            Text(L10n.text("effects.bypassedTitle"))
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Text(L10n.text("effects.bypassedBody"))
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, AppTheme.spaceMD)
        .ongakuPanel()
    }
}

private struct MasonryEffectLayout: Layout {
    let minimumColumnWidth: CGFloat
    let maximumColumnWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        // AppKit probes the hosting view with an unbounded width when calculating
        // window size limits. Do not convert that proposal to an integer column count.
        let proposedWidth = proposal.width ?? minimumColumnWidth
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : minimumColumnWidth
        let result = arrangement(width: width, subviews: subviews)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: result.columnWidth, height: nil)
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> Arrangement {
        let columnCount = Int(min(
            CGFloat(max(1, subviews.count)),
            max(1, (width + spacing) / (minimumColumnWidth + spacing))
        ))
        let availableColumnWidth = (
            width - (CGFloat(columnCount - 1) * spacing)
        ) / CGFloat(columnCount)
        let columnWidth = min(maximumColumnWidth, availableColumnWidth)
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var origins: [CGPoint] = []
        origins.reserveCapacity(subviews.count)

        for subview in subviews {
            let column = columnHeights.indices.min {
                columnHeights[$0] < columnHeights[$1]
            } ?? 0
            let size = subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            origins.append(
                CGPoint(
                    x: CGFloat(column) * (columnWidth + spacing),
                    y: columnHeights[column]
                )
            )
            columnHeights[column] += size.height + spacing
        }

        let height = max(0, (columnHeights.max() ?? 0) - spacing)
        return Arrangement(columnWidth: columnWidth, origins: origins, height: height)
    }

    private struct Arrangement {
        let columnWidth: CGFloat
        let origins: [CGPoint]
        let height: CGFloat
    }
}

/// These small grids must report their complete height to the masonry layout.
/// LazyVGrid estimates offscreen rows; re-estimation during a parameter edit can
/// change the document height and move cards underneath the pointer.
private struct EffectParameterLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(width: proposal.width, subviews: subviews)
        return CGSize(width: result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.origins[index].x, y: bounds.minY + result.origins[index].y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: result.cellWidth, height: nil)
            )
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> Arrangement {
        let proposed = proposedWidth ?? 84
        let width = proposed.isFinite ? max(0, proposed) : 84
        let count = Int(min(
            CGFloat(max(1, subviews.count)),
            max(1, (width + horizontalSpacing) / (84 + horizontalSpacing))
        ))
        let cellWidth = min(92, max(0,
            (width - CGFloat(count - 1) * horizontalSpacing) / CGFloat(count)
        ))
        var origins: [CGPoint] = []
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            if index > 0 && index.isMultiple(of: count) {
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: CGFloat(index % count) * (cellWidth + horizontalSpacing), y: y))
            rowHeight = max(rowHeight, subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height)
        }
        return Arrangement(width: width, cellWidth: cellWidth, origins: origins, height: y + rowHeight)
    }

    private struct Arrangement {
        let width: CGFloat
        let cellWidth: CGFloat
        let origins: [CGPoint]
        let height: CGFloat
    }
}

private struct EffectModuleCard: View {
    @EnvironmentObject private var input: EffectRackInputRouter
    @EnvironmentObject private var player: PlaybackController
    let kind: RealtimeAudioEffectKind

    private var setting: RealtimeAudioEffectSetting {
        player.effectSetting(for: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            header

            Divider().overlay(AppTheme.rule)

            if kind == .equalizer {
                ForEach(EqualizerParameterSection.all) { section in
                    VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                        HStack(spacing: AppTheme.spaceXS) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryInk)
                                .fixedSize()
                            Rectangle()
                                .fill(AppTheme.rule)
                                .frame(height: 1)
                        }
                        parameterControls(section.parameters)
                    }
                }
            } else {
                parameterControls(kind.parameterDefinitions)
            }
        }
        .padding(AppTheme.spaceMD)
        .ongakuPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                .stroke(setting.isEnabled ? AppTheme.accent.opacity(0.42) : AppTheme.rule.opacity(0.55), lineWidth: 1)
        }
    }

    private func parameterControls(_ definitions: [EffectParameterDefinition]) -> some View {
        EffectParameterLayout(
            horizontalSpacing: kind == .equalizer ? AppTheme.spaceXS : AppTheme.spaceSM,
            verticalSpacing: AppTheme.spaceMD
        ) {
            ForEach(definitions, id: \.key) { definition in
                if isDiscrete(definition) {
                    MiniToggleSwitch(
                        isOn: binaryBinding(definition),
                        label: definition.name,
                        valueText: displayValue(for: definition)
                    )
                    .disabled(!setting.isEnabled)
                } else {
                    RotaryKnob(
                        value: parameterBinding(definition),
                        range: definition.range,
                        defaultValue: definition.defaultValue,
                        label: definition.name,
                        valueText: displayValue(for: definition)
                    )
                    .disabled(!setting.isEnabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.spaceXS)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.spaceSM) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: AppTheme.spaceXS) {
                    Circle()
                        .fill(setting.isEnabled ? AppTheme.good : AppTheme.rule)
                        .frame(width: 7, height: 7)
                    Text(kind.displayName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                }
                Text(kind.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.spaceSM)

            Button {
                guard !input.isScrolling else { return }
                player.resetEffect(kind)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)
            .help(L10n.text("effects.reset"))
            .effectRackControl()

            SquareLeverToggle(
                isOn: Binding(
                    get: { setting.isEnabled },
                    set: { if !input.isScrolling { player.setEffectEnabled($0, for: kind) } }
                ),
                accessibilityLabel: kind.displayName
            )
            .help(setting.isEnabled ? L10n.text("effects.disable") : L10n.text("effects.enable"))
        }
    }

    private func parameterBinding(_ definition: EffectParameterDefinition) -> Binding<Double> {
        Binding(
            get: { setting.parameters[definition.key] ?? definition.defaultValue },
            set: { if !input.isScrolling { player.setEffectParameter($0, key: definition.key, for: kind) } }
        )
    }

    private func binaryBinding(_ definition: EffectParameterDefinition) -> Binding<Bool> {
        Binding(
            get: { (setting.parameters[definition.key] ?? definition.defaultValue) >= 0.5 },
            set: { if !input.isScrolling { player.setEffectParameter($0 ? 1 : 0, key: definition.key, for: kind) } }
        )
    }

    private func isDiscrete(_ definition: EffectParameterDefinition) -> Bool {
        ["mode", "openTone", "lmfFocus", "hmfFocus", "mc901"].contains(definition.key)
    }

    private func displayValue(for definition: EffectParameterDefinition) -> String {
        let value = setting.parameters[definition.key] ?? definition.defaultValue
        if isDiscrete(definition) {
            switch (kind, definition.key) {
            case (.exciter, "mode"): return ExciterMode.from(parameterValue: value).title
            case (.exciter, "openTone"): return ExciterOpenTone.from(parameterValue: value).title
            case (.bbe, "mode"): return MaximizerMode.from(parameterValue: value).title
            default: return value >= 0.5 ? L10n.text("effects.on") : L10n.text("effects.off")
            }
        }
        if definition.isBiPolar {
            return String(format: "%+.0f%%", (value * 2 - 1) * 100)
        }
        return String(format: "%.0f%%", value * 100)
    }
}

/// Presentation sections use the existing DSP parameter groups and key order.
struct EqualizerParameterSection: Identifiable {
    let id: String
    let title: String
    let parameters: [EffectParameterDefinition]

    static var all: [Self] {
        let definitions = RealtimeAudioEffectKind.equalizer.parameterDefinitions
        let groups = [("FILTER", "filter"), ("LOW BAND", "low"), ("LMF", "lowMid"),
                      ("HMF", "highMid"), ("HIGH BAND", "high"), ("OUTPUT", "output")]
        return groups.map { group, key in
            Self(id: group, title: L10n.text("effects.eqGroup.\(key)"),
                 parameters: definitions.filter { $0.group == group })
        }
    }
}
