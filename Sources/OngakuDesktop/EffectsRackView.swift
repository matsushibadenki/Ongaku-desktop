/* Hallmark · pre-emit critique: P5 H4 E4 S5 R4 V3
 * component: effects rack · genre: atmospheric · macrostructure: Workbench extension
 * theme: Midnight · hierarchy: tab > module > parameters
 * density: compact desktop workbench · grid: adaptive
 */
import SwiftUI

struct EffectsRackView: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var selectedTab: AudioEffectPageTab = .basic

    private var visibleKinds: [RealtimeAudioEffectKind] {
        let allowed = AudioEffectModuleRegistry.activeKinds(for: selectedTab)
        return AudioEffectModuleRegistry.activeKinds.filter(allowed.contains)
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
            .padding(.bottom, AppTheme.effectsRackBottomClearance)
        }
        .onAppear {
            selectedTab = player.effectsBypassed ? .off : .basic
        }
        .onChange(of: selectedTab) { _, newValue in
            player.setEffectsBypassed(newValue == .off)
        }
    }

    private var rackToolbar: some View {
        HStack(spacing: AppTheme.spaceMD) {
            Picker(L10n.text("effects.mode"), selection: $selectedTab) {
                ForEach(AudioEffectPageTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
                .lineLimit(2)

            Spacer(minLength: AppTheme.spaceMD)

            Label(
                L10n.format("effects.enabledShort", player.enabledEffectCount),
                systemImage: "waveform.path.ecg"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(player.enabledEffectCount > 0 ? AppTheme.good : AppTheme.secondaryInk)
        }
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
        let width = proposal.width ?? minimumColumnWidth
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
        let columnCount = max(
            1,
            Int((width + spacing) / (minimumColumnWidth + spacing))
        )
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

private struct EffectModuleCard: View {
    @EnvironmentObject private var player: PlaybackController
    let kind: RealtimeAudioEffectKind

    private var setting: RealtimeAudioEffectSetting {
        player.effectSetting(for: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            header

            Divider().overlay(AppTheme.rule)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 84, maximum: 92), spacing: AppTheme.spaceSM)],
                alignment: .leading,
                spacing: AppTheme.spaceMD
            ) {
                ForEach(kind.parameterDefinitions, id: \.key) { definition in
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
        .padding(AppTheme.spaceMD)
        .ongakuPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                .stroke(setting.isEnabled ? AppTheme.accent.opacity(0.42) : AppTheme.rule.opacity(0.55), lineWidth: 1)
        }
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
                player.resetEffect(kind)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)
            .help(L10n.text("effects.reset"))

            SquareLeverToggle(
                isOn: Binding(
                    get: { setting.isEnabled },
                    set: { player.setEffectEnabled($0, for: kind) }
                ),
                accessibilityLabel: kind.displayName
            )
            .help(setting.isEnabled ? L10n.text("effects.disable") : L10n.text("effects.enable"))
        }
    }

    private func parameterBinding(_ definition: EffectParameterDefinition) -> Binding<Double> {
        Binding(
            get: { setting.parameters[definition.key] ?? definition.defaultValue },
            set: { player.setEffectParameter($0, key: definition.key, for: kind) }
        )
    }

    private func binaryBinding(_ definition: EffectParameterDefinition) -> Binding<Bool> {
        Binding(
            get: { (setting.parameters[definition.key] ?? definition.defaultValue) >= 0.5 },
            set: { player.setEffectParameter($0 ? 1 : 0, key: definition.key, for: kind) }
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
