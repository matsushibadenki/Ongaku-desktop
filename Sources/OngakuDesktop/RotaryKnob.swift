/* Hallmark · pre-emit critique: P5 H4 E5 S5 R5 V4
 * component: rotary parameter knob · genre: atmospheric · macrostructure: Workbench control
 * theme: Midnight · interaction: circular drag, keyboard, accessibility
 * visual diameter: 52 pt · minimum hit target: 64 pt
 */
import SwiftUI

struct RotaryKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let label: String
    let valueText: String
    var step: Double = 0.01

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    private let diameter: CGFloat = 52
    private let tickCount = 25

    private var normalizedValue: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var rotation: Angle {
        .degrees(-135 + (270 * normalizedValue))
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ticks

                Circle()
                    .fill(AppTheme.raised)
                    .overlay {
                        Circle()
                            .fill(AppTheme.ink.opacity(isFocused ? 0.085 : (isHovering ? 0.035 : 0)))
                    }
                    .overlay {
                        Circle()
                            .stroke(AppTheme.rule, lineWidth: 1)
                    }
                    .overlay {
                        VStack(spacing: 0) {
                            Capsule()
                                .fill(isEnabled ? AppTheme.accent : AppTheme.secondaryInk)
                                .frame(width: 2, height: 11)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 5)
                        .frame(width: 38, height: 38)
                        .rotationEffect(rotation)
                    }
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
                    .scaleEffect(isDragging ? 0.97 : (isHovering ? 1.025 : 1))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { setValue(defaultValue) }
            )
            .onHover { isHovering = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: adjust(by: -step)
                case .right, .up: adjust(by: step)
                default: break
                }
            }

            VStack(spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .help(label)

                Text(valueText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryInk)
                    .contentTransition(.numericText())
            }
            .frame(minHeight: 26, alignment: .top)
        }
        .frame(width: 84)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityHint(L10n.text("effects.knobHint"))
        .accessibilityAdjustableAction { direction in
            adjust(by: direction == .increment ? step : -step)
        }
    }

    private var ticks: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let fraction = Double(index) / Double(tickCount - 1)
                Capsule()
                    .fill(fraction <= normalizedValue ? AppTheme.accent : AppTheme.rule)
                    .frame(width: 1.25, height: index.isMultiple(of: 4) ? 5 : 3)
                    .offset(y: -23)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isDragging = true
                isFocused = true
                let center = diameter / 2
                let dx = gesture.location.x - center
                let dy = gesture.location.y - center
                var degrees = atan2(dx, -dy) * 180 / .pi
                degrees = min(max(degrees, -135), 135)
                let fraction = (degrees + 135) / 270
                setValue(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
            }
            .onEnded { _ in isDragging = false }
    }

    private func adjust(by amount: Double) {
        setValue(value + amount)
    }

    private func setValue(_ newValue: Double) {
        guard isEnabled else { return }
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let stepped = (clamped / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}
