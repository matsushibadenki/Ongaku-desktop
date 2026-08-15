/* Hallmark · pre-emit critique: P5 H4 E5 S5 R5 V4
 * component: two-position hardware toggle · genre: atmospheric · theme: Midnight
 * states: default · hover · focus · active · disabled · semantic value feedback
 */
import SwiftUI

struct MiniToggleSwitch: View {
    @Binding var isOn: Bool
    let label: String
    let valueText: String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 5) {
            Button {
                isOn.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.raised)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.ink.opacity(isHovering || isFocused ? 0.055 : 0))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isFocused ? AppTheme.accent : AppTheme.rule, lineWidth: 1)
                        }

                    Capsule()
                        .fill(AppTheme.canvas)
                        .frame(width: 9, height: 31)
                        .overlay {
                            Capsule().stroke(AppTheme.rule.opacity(0.7), lineWidth: 1)
                        }

                    Capsule()
                        .fill(AppTheme.secondaryInk)
                        .frame(width: 3, height: 19)
                        .offset(y: isOn ? -5 : 5)

                    Circle()
                        .fill(isOn ? AppTheme.accent : AppTheme.secondaryInk)
                        .overlay {
                            Circle().stroke(AppTheme.ink.opacity(0.25), lineWidth: 1)
                        }
                        .frame(width: 13, height: 13)
                        .offset(y: isOn ? -10 : 10)

                    Circle()
                        .fill(isOn ? AppTheme.good : AppTheme.rule)
                        .frame(width: 4, height: 4)
                        .offset(x: 11, y: -17)
                }
                .frame(width: 34, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(HardwareToggleButtonStyle())
            .focused($isFocused)
            .onHover { isHovering = $0 }

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(height: 26, alignment: .top)
                .help(label)

            Text(valueText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isOn ? AppTheme.accent : AppTheme.secondaryInk)
                .lineLimit(1)
        }
        .frame(width: 84)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityHint(L10n.text("effects.toggleHint"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityAction { if isEnabled { isOn.toggle() } }
    }
}

private struct HardwareToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
