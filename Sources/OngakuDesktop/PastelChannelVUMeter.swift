import SwiftUI

/// Compact desktop counterpart of the iPhone ceramic meter. Both draw their
/// ticks and needle from PastelVUMeterScale; the desktop aperture stays wide.
struct PastelChannelVUMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let channel: String
    let level: Double
    let backlight: Color
    let isActive: Bool
    let appearance: AppAppearance

    private let ink = Color(red: 0.27, green: 0.20, blue: 0.24)
    private let overload = Color(red: 0.72, green: 0.23, blue: 0.29)
    private var position: Double {
        let rmsDBFS = (level.isFinite ? min(1, max(0, level)) : 0) * 60 - 60
        return PastelVUMeterScale.position(forLevel: PastelVUMeterScale.normalizedValue(rmsDBFS: rmsDBFS))
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: appearance.meterFrameColors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(appearance.meterFrameColors[0], lineWidth: 1))
                .shadow(color: appearance.accentColor!.opacity(0.20), radius: 2, y: 1)
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.96, green: 0.91, blue: 0.79))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .padding(.horizontal, 11).padding(.vertical, 5)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.86, blue: 0.60), Color(red: 1, green: 0.97, blue: 0.84)],
                                         startPoint: .top, endPoint: .bottom))
                Canvas { context, size in
                    let geometry = PastelCompactVUGeometry(size: size)
                    func drawText(_ text: String, _ point: CGPoint, _ fontSize: CGFloat, _ color: Color = Color(red: 0.27, green: 0.20, blue: 0.24)) {
                        context.draw(Text(text).font(.system(size: fontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(color), at: point)
                    }
                    drawText("#Ongaku", CGPoint(x: size.width / 2, y: 7), 9)
                    drawText(channel, CGPoint(x: size.width - 8, y: 7), 7)
                    context.fill(Path(ellipseIn: CGRect(x: 6, y: 4, width: 4, height: 4)), with: .color(backlight))
                    drawText("PROFESSIONAL VU METER", CGPoint(x: size.width / 2, y: 17), 4.7)
                    for (a, b) in zip(PastelVUMeterScale.marks, PastelVUMeterScale.marks.dropFirst()) {
                        let point = geometry.point(position: (a.position + b.position) / 2)
                        var tick = Path(); tick.move(to: point)
                        tick.addLine(to: CGPoint(x: point.x, y: point.y - 3))
                        context.stroke(tick, with: .color(a.vu >= 0 ? overload : ink), lineWidth: 0.5)
                    }
                    for mark in PastelVUMeterScale.marks {
                        let point = geometry.point(position: mark.position)
                        var tick = Path(); tick.move(to: point)
                        tick.addLine(to: CGPoint(x: point.x, y: point.y - 5))
                        context.stroke(tick, with: .color(mark.vu > 0 ? overload : ink), lineWidth: mark.vu == 0 ? 1.1 : 0.6)
                        let label = mark.vu > 0 ? "+\(mark.vu)" : "\(mark.vu)"
                        drawText(label, CGPoint(x: point.x, y: point.y - 9), 6, mark.vu > 0 ? overload : ink)
                        if PastelVUMeterScale.secondaryMarks.contains(mark.vu) {
                            drawText(label, CGPoint(x: point.x, y: point.y + 7), 5, mark.vu == 0 ? overload : ink)
                        }
                    }
                    for positive in [false, true] {
                        let lower = positive ? 0.73 : 0
                        let upper = positive ? 1 : 0.73
                        var arc = Path()
                        for step in 0...64 {
                            let point = geometry.point(position: lower + (upper - lower) * Double(step) / 64)
                            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
                        }
                        context.stroke(arc, with: .color(positive ? overload : ink), lineWidth: positive ? 1.8 : 0.8)
                    }
                    drawText("VU · dB", CGPoint(x: size.width / 2, y: size.height - 6), 7)
                }
                PastelCompactVUNeedle(position: position)
                    .stroke(ink, style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                    .animation(reduceMotion ? nil : .smooth(duration: VUMeterMotion.duration(isActive: isActive), extraBounce: 0), value: position)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.brown.opacity(0.4), lineWidth: 0.7))
            .padding(.horizontal, 16).padding(.vertical, 8)
            GeometryReader { proxy in
                ForEach(0..<4) { index in
                    Circle().fill(LinearGradient(colors: [appearance.meterFrameColors[0], appearance.meterFrameColors[1]], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(appearance.accentColor!.opacity(0.30), lineWidth: 0.5))
                        .frame(width: 4, height: 4)
                        .position(x: index % 2 == 0 ? 6 : proxy.size.width - 6,
                                  y: index < 2 ? 12 : proxy.size.height - 12)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel) \(L10n.text("meter.vu"))")
    }
}

struct PastelCompactVUGeometry {
    let size: CGSize
    var pivot: CGPoint { CGPoint(x: size.width / 2, y: size.height + 6) }
    func point(position: Double) -> CGPoint {
        let p = position.isFinite ? min(1, max(0, position)) : 0
        return CGPoint(x: 9 + (size.width - 18) * p, y: size.height * 0.65 - 6 * sin(.pi * p))
    }
}

struct PastelCompactVUNeedle: Shape {
    var position: Double
    var animatableData: Double { get { position } set { position = newValue } }
    func path(in rect: CGRect) -> Path {
        let geometry = PastelCompactVUGeometry(size: rect.size)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + geometry.pivot.x, y: rect.minY + geometry.pivot.y))
        let tip = geometry.point(position: position)
        path.addLine(to: CGPoint(x: rect.minX + tip.x, y: rect.minY + tip.y))
        return path
    }
}
