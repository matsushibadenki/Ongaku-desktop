/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5
 * component: persistent player transport · genre: atmospheric · theme: Midnight
 * states: native macOS default · hover · focus · active · disabled · playback feedback
 */
import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @State private var isShowingVolume = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.rule)
            GeometryReader { proxy in
                let blockWidth = proxy.size.width / 4
                HStack(spacing: 0) {
                    meterCell(
                        channel: "L",
                        level: player.stereoLevels.left,
                        bands: player.stereoSpectrum.left
                    )
                        .frame(width: blockWidth)
                    centerPlayerArea
                        .frame(width: blockWidth * 2)
                    meterCell(
                        channel: "R",
                        level: player.stereoLevels.right,
                        bands: player.stereoSpectrum.right
                    )
                        .frame(width: blockWidth)
                }
            }
            .frame(height: 104)
            .background(AppTheme.surface)
            Divider().overlay(AppTheme.rule)
        }
    }

    @ViewBuilder
    private func meterCell(channel: String, level: Double, bands: [Double]) -> some View {
        Group {
            switch meterSettings.style {
            case .spectrum:
                ChannelSpectrumView(channel: channel, bands: bands)
            case .vu:
                ChannelVUMeterView(
                    channel: channel,
                    level: level,
                    backlight: meterSettings.backlight.color,
                    isActive: player.isPlaying
                )
            }
        }
        .padding(.horizontal, AppTheme.spaceMD)
        .padding(.vertical, AppTheme.spaceSM)
        .overlay(alignment: channel == "L" ? .trailing : .leading) {
            Rectangle()
                .fill(AppTheme.rule.opacity(0.42))
                .frame(width: 1)
        }
    }

    private var centerPlayerArea: some View {
        VStack(spacing: AppTheme.spaceSM) {
            HStack(spacing: AppTheme.spaceSM) {
                playerMetadata
                    .frame(maxWidth: .infinity, alignment: .leading)

                PlayerTransportControls()
                    .fixedSize()

                playerUtilities
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: AppTheme.spaceSM) {
                Text(DurationFormatter.string(displayedElapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(width: 42, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { displayedElapsed },
                        set: { newValue in
                            if appleMusicPlayback.currentItem != nil {
                                appleMusicPlayback.seek(to: newValue)
                            } else {
                                player.seek(to: newValue)
                            }
                        }
                    ),
                    in: 0...max(displayedDuration, 1)
                )
                .disabled(
                    appleMusicPlayback.currentItem != nil
                        ? displayedDuration <= 0
                        : player.currentTrack == nil
                )
                .accessibilityLabel(L10n.text("miniPlayer.progress"))
                Text(DurationFormatter.string(displayedDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(width: 42, alignment: .leading)
            }
        }
        .padding(.horizontal, AppTheme.spaceMD)
        .padding(.vertical, AppTheme.spaceSM)
    }

    private var playerMetadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metadataSubtitle)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryInk)
                .lineLimit(1)
            Text(metadataTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
        }
        .help(metadataHelp)
    }

    private var playerUtilities: some View {
        HStack(spacing: AppTheme.spaceXS) {
            if appleMusicPlayback.currentItem != nil {
                Label("Apple Music", systemImage: "apple.logo")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryInk)
                PlaybackQueueButton()
            } else {
                PlaybackModeMenu()
                PlaybackQueueButton()
                Button {
                    isShowingVolume.toggle()
                } label: {
                    Image(systemName: volumeSymbol)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L10n.text("miniPlayer.volume"))
                .accessibilityLabel(L10n.text("miniPlayer.volume"))
                .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
                .popover(isPresented: $isShowingVolume, arrowEdge: .bottom) {
                    volumePopover
                }
            }
        }
        .fixedSize()
    }

    private var volumePopover: some View {
        HStack(spacing: AppTheme.spaceSM) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(AppTheme.secondaryInk)
            Slider(value: $player.volume, in: 0...1)
                .frame(width: 160)
                .accessibilityLabel(L10n.text("miniPlayer.volume"))
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(AppTheme.secondaryInk)
        }
        .padding(AppTheme.spaceMD)
        .background(AppTheme.surface)
    }

    private var metadataHelp: String {
        if let queueItem = appleMusicPlayback.currentQueueItem {
            return "\(queueItem.subtitle) — \(queueItem.title)"
        }
        if let item = appleMusicPlayback.currentItem {
            return "\(item.subtitle) — \(item.title)"
        }
        guard let track = player.currentTrack else { return L10n.text("player.chooseTrack") }
        return "\(track.album) — \(track.title)"
    }

    private var metadataTitle: String {
        appleMusicPlayback.currentQueueItem?.title
            ?? appleMusicPlayback.currentItem?.title
            ?? player.currentTrack?.title
            ?? L10n.text("player.idle")
    }

    private var metadataSubtitle: String {
        appleMusicPlayback.currentQueueItem?.subtitle
            ?? appleMusicPlayback.currentItem?.subtitle
            ?? player.currentTrack?.album
            ?? L10n.text("player.chooseTrack")
    }

    private var displayedElapsed: TimeInterval {
        appleMusicPlayback.currentItem == nil ? player.elapsed : appleMusicPlayback.elapsed
    }

    private var displayedDuration: TimeInterval {
        appleMusicPlayback.currentItem == nil ? player.duration : appleMusicPlayback.duration
    }

    private var volumeSymbol: String {
        switch player.volume {
        case ...0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/* Hallmark · component: analog VU meter · genre: atmospheric · theme: vintage hi-fi
 * states: idle · active · overload · reduced motion
 * contrast: dark ink on warm illuminated dial
 */
struct ChannelVUMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let channel: String
    let level: Double
    let backlight: Color
    var isActive = true

    private let scaleMarks = VUMeterCalibration.scaleMarks

    var body: some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MeterPalette.frameTop, MeterPalette.frameBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    MeterPalette.dialTop,
                                    MeterPalette.dialMiddle,
                                    MeterPalette.dialBottom,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    MeterLEDSpotlight(color: backlight)

                    dial()

                    LinearGradient(
                        colors: [Color.white.opacity(0.28), .clear, MeterPalette.glassShade],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(4)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(MeterPalette.innerRim, lineWidth: 1)
                    .padding(4)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MeterPalette.outerRim, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel) \(L10n.text("meter.vu"))")
        .accessibilityValue("\(Int((clampedLevel * 100).rounded()))%")
    }

    private func dial() -> some View {
        ZStack {
            Canvas { context, canvasSize in
                // The physical hinge is deliberately below the window. SwiftUI clips the
                // long needle and shallow arc to the wide meter aperture.
                let geometry = VUMeterGeometry.layout(for: canvasSize)
                let pivot = geometry.pivot
                let scaleRadius = geometry.scaleRadius
                let angleForPosition = { (position: Double) in
                    geometry.angle(position: position)
                }

                var outerArc = Path()
                var innerArc = Path()
                for index in 0...64 {
                    let position = Double(index) / 64
                    let angle = angleForPosition(position)
                    let outerPoint = point(from: pivot, radius: scaleRadius, angle: angle)
                    let innerPoint = point(from: pivot, radius: scaleRadius - 9, angle: angle)
                    if index == 0 {
                        outerArc.move(to: outerPoint)
                        innerArc.move(to: innerPoint)
                    } else {
                        outerArc.addLine(to: outerPoint)
                        innerArc.addLine(to: innerPoint)
                    }
                }
                context.stroke(outerArc, with: .color(MeterPalette.scaleInk.opacity(0.72)), lineWidth: 1)
                context.stroke(innerArc, with: .color(MeterPalette.scaleInk.opacity(0.52)), lineWidth: 0.75)

                var overloadArc = Path()
                for index in 0...18 {
                    let position = 0.79 + (0.21 * Double(index) / 18)
                    let arcPoint = point(
                        from: pivot,
                        radius: scaleRadius - 9,
                        angle: angleForPosition(position)
                    )
                    if index == 0 {
                        overloadArc.move(to: arcPoint)
                    } else {
                        overloadArc.addLine(to: arcPoint)
                    }
                }
                context.stroke(overloadArc, with: .color(MeterPalette.overload.opacity(0.82)), lineWidth: 1.4)

                for index in 0...32 {
                    let position = Double(index) / 32
                    let angle = angleForPosition(position)
                    let outer = point(from: pivot, radius: scaleRadius, angle: angle)
                    let inner = point(from: pivot, radius: scaleRadius - 4, angle: angle)
                    var tick = Path()
                    tick.move(to: inner)
                    tick.addLine(to: outer)
                    context.stroke(
                        tick,
                        with: .color(position >= 0.79
                            ? MeterPalette.overload.opacity(0.72)
                            : MeterPalette.scaleInk.opacity(0.54)),
                        lineWidth: 0.65
                    )
                }

                for mark in scaleMarks {
                    let decibels = mark.decibels
                    let position = mark.position
                    let angle = angleForPosition(position)
                    let outer = point(from: pivot, radius: scaleRadius + 1, angle: angle)
                    let inner = point(
                        from: pivot,
                        radius: scaleRadius - (decibels >= 0 ? 11 : 8),
                        angle: angle
                    )
                    var tick = Path()
                    tick.move(to: inner)
                    tick.addLine(to: outer)
                    context.stroke(
                        tick,
                        with: .color(decibels > 0 ? MeterPalette.overload : MeterPalette.scaleInk),
                        lineWidth: decibels == 0 ? 1.45 : 0.95
                    )

                    var labelPoint = point(from: pivot, radius: scaleRadius - 18, angle: angle)
                    labelPoint.y = min(labelPoint.y, canvasSize.height - 8)
                    let label = context.resolve(
                        Text(decibels > 0 ? "+\(decibels)" : "\(decibels)")
                            .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(decibels > 0 ? MeterPalette.overload : MeterPalette.scaleInk)
                    )
                    context.draw(label, at: labelPoint, anchor: .center)
                }

                let powerLabel = context.resolve(
                    Text("POWER / WATTS")
                        .font(.system(size: 5.5, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(MeterPalette.scaleInk.opacity(0.68))
                )
                context.draw(powerLabel, at: CGPoint(x: pivot.x, y: 7), anchor: .center)

                let vuLabel = context.resolve(
                    Text("VU")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(MeterPalette.scaleInk.opacity(0.68))
                )
                context.draw(vuLabel, at: CGPoint(x: pivot.x, y: canvasSize.height * 0.64))

                let channelLabel = context.resolve(
                    Text(channel)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(MeterPalette.scaleInk.opacity(0.72))
                )
                context.draw(
                    channelLabel,
                    at: CGPoint(x: canvasSize.width - 11, y: 9),
                    anchor: .center
                )
            }

            VUMeterNeedle(position: needlePosition)
                .animation(
                    reduceMotion
                        ? nil
                        : .smooth(
                            duration: VUMeterMotion.duration(isActive: isActive),
                            extraBounce: 0
                        ),
                    value: needlePosition
                )
        }
    }

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    private var needlePosition: Double {
        VUMeterCalibration.needlePosition(forNormalizedRMS: clampedLevel)
    }

    private func point(from pivot: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: pivot.x + (sin(angle) * radius),
            y: pivot.y - (cos(angle) * radius)
        )
    }
}

enum VUMeterCalibration {
    /// Conventional alignment: a -18 dBFS RMS program signal reads 0 VU.
    static let referenceDBFS = -18.0
    static let floorDBFS = -60.0
    static let scaleMarks: [(decibels: Int, position: Double)] = [
        (-40, 0.00),
        (-30, 0.11),
        (-20, 0.23),
        (-10, 0.38),
        (-7, 0.49),
        (-5, 0.58),
        (-3, 0.68),
        (0, 0.84),
        (3, 1.00),
    ]

    static func needlePosition(forNormalizedRMS level: Double) -> Double {
        let clampedLevel = min(max(level, 0), 1)
        let dbfs = (clampedLevel * -floorDBFS) + floorDBFS
        return position(forVUDecibels: dbfs - referenceDBFS)
    }

    private static func position(forVUDecibels decibels: Double) -> Double {
        guard let first = scaleMarks.first, let last = scaleMarks.last else { return 0 }
        guard decibels > Double(first.decibels) else { return first.position }
        guard decibels < Double(last.decibels) else { return last.position }

        for (lower, upper) in zip(scaleMarks, scaleMarks.dropFirst()) {
            let lowerDB = Double(lower.decibels)
            let upperDB = Double(upper.decibels)
            guard decibels >= lowerDB, decibels <= upperDB else { continue }
            let progress = (decibels - lowerDB) / (upperDB - lowerDB)
            return lower.position + ((upper.position - lower.position) * progress)
        }
        return last.position
    }
}

enum VUMeterMotion {
    static let trackingDuration: TimeInterval = 0.14
    static let settlingDuration: TimeInterval = 0.65

    static func duration(isActive: Bool) -> TimeInterval {
        isActive ? trackingDuration : settlingDuration
    }
}

enum VUMeterGeometry {
    static let horizontalInset: CGFloat = 12
    static let arcApexHeightRatio: CGFloat = 0.30
    static let arcEndpointHeightRatio: CGFloat = 0.55
    static let needleExtension: CGFloat = 6

    static func layout(for size: CGSize) -> VUMeterLayout {
        let apexY = size.height * arcApexHeightRatio
        let endpointY = size.height * arcEndpointHeightRatio
        let sagitta = max(endpointY - apexY, 1)
        let halfChord = max((size.width / 2) - horizontalInset, 1)
        let radius = ((halfChord * halfChord) + (sagitta * sagitta)) / (2 * sagitta)
        let halfAngle = asin(min(halfChord / radius, 1))

        return VUMeterLayout(
            pivot: CGPoint(x: size.width / 2, y: apexY + radius),
            scaleRadius: radius,
            needleRadius: radius + needleExtension,
            halfAngle: halfAngle
        )
    }
}

struct VUMeterLayout {
    let pivot: CGPoint
    let scaleRadius: CGFloat
    let needleRadius: CGFloat
    let halfAngle: Double

    func angle(position: Double) -> Double {
        -halfAngle + ((halfAngle * 2) * min(max(position, 0), 1))
    }

    func needleTip(position: Double) -> CGPoint {
        let angle = angle(position: position)
        return CGPoint(
            x: pivot.x + (sin(angle) * needleRadius),
            y: pivot.y - (cos(angle) * needleRadius)
        )
    }
}

struct VUMeterNeedle: View, @MainActor Animatable {
    var position: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        Canvas { context, canvasSize in
            let geometry = VUMeterGeometry.layout(for: canvasSize)
            let needleEnd = geometry.needleTip(position: position)
            var needle = Path()
            needle.move(to: geometry.pivot)
            needle.addLine(to: needleEnd)
            context.stroke(needle, with: .color(MeterPalette.needleShadow), lineWidth: 3.2)
            context.stroke(needle, with: .color(MeterPalette.needle), lineWidth: 1.15)
        }
    }
}

private enum MeterPalette {
    static let frameTop = Color(red: 0.13, green: 0.12, blue: 0.10)
    static let frameBottom = Color(red: 0.025, green: 0.027, blue: 0.026)
    static let outerRim = Color.white.opacity(0.12)
    static let innerRim = Color(red: 0.08, green: 0.065, blue: 0.045).opacity(0.72)
    static let dialTop = Color(red: 0.95, green: 0.89, blue: 0.72)
    static let dialMiddle = Color(red: 0.84, green: 0.75, blue: 0.56)
    static let dialBottom = Color(red: 0.64, green: 0.52, blue: 0.34)
    static let scaleInk = Color(red: 0.12, green: 0.105, blue: 0.08)
    static let overload = Color(red: 0.56, green: 0.10, blue: 0.065)
    static let needle = Color(red: 0.63, green: 0.12, blue: 0.07)
    static let needleShadow = Color.black.opacity(0.58)
    static let glassShade = Color.black.opacity(0.12)
}

private struct MeterLEDSpotlight: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            // A broad, softly scattered beam reveals the paper texture without
            // washing out the scale. Its emitter sits below the cropped window.
            SpotlightCone(topWidthFraction: 0.84, sourceWidth: 7)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: color.opacity(0.025), location: 0),
                            .init(color: color.opacity(0.10), location: 0.54),
                            .init(color: color.opacity(0.38), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blur(radius: 8)

            // The narrower core gives the light a clear direction, like a small
            // LED recessed under the faceplate rather than a generic gradient.
            SpotlightCone(topWidthFraction: 0.34, sourceWidth: 3)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: color.opacity(0.018), location: 0),
                            .init(color: color.opacity(0.13), location: 0.58),
                            .init(color: color.opacity(0.48), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blur(radius: 2.8)

            RadialGradient(
                stops: [
                    .init(color: Color.white.opacity(0.42), location: 0),
                    .init(color: color.opacity(0.46), location: 0.08),
                    .init(color: color.opacity(0.18), location: 0.34),
                    .init(color: .clear, location: 1),
                ],
                center: .bottom,
                startRadius: 0,
                endRadius: 62
            )

            Capsule()
                .fill(Color.white.opacity(0.78))
                .frame(width: 12, height: 2)
                .shadow(color: color.opacity(0.95), radius: 4)
                .offset(y: 1)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SpotlightCone: Shape {
    let topWidthFraction: CGFloat
    let sourceWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let topHalfWidth = rect.width * topWidthFraction / 2
        let sourceY = rect.maxY + 8
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - sourceWidth / 2, y: sourceY))
        path.addLine(to: CGPoint(x: rect.midX - topHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + topHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + sourceWidth / 2, y: sourceY))
        path.closeSubpath()
        return path
    }
}

private struct ChannelSpectrumView: View {
    let channel: String
    let bands: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(channel)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(AppTheme.secondaryInk)

            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(AppTheme.rule.opacity(0.72))
                        .frame(height: 1)

                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                            SpectrumBar(value: value, availableHeight: proxy.size.height)
                        }
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .bottom
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel) \(L10n.text("miniPlayer.stereoMeter"))")
        .accessibilityValue(averageLevel)
    }

    private var averageLevel: String {
        guard !bands.isEmpty else { return "0%" }
        let average = bands.reduce(0, +) / Double(bands.count)
        return "\(Int((average * 100).rounded()))%"
    }
}

private struct SpectrumBar: View {
    let value: Double
    let availableHeight: CGFloat

    var body: some View {
        Capsule()
            .fill(AppTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: max(2, availableHeight * SpectrumPresentation.height(for: value)))
            .opacity(value > 0.015 ? 1 : 0.24)
            .animation(.linear(duration: 0.08), value: value)
    }
}

enum SpectrumPresentation {
    private static let displayGain = 1.65
    private static let responseCurve = 0.82

    nonisolated static func height(for value: Double) -> Double {
        let amplified = min(max(value, 0) * displayGain, 1)
        return pow(amplified, responseCurve)
    }
}

struct PlayerTransportControls: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController

    var compact = false

    var body: some View {
        HStack(spacing: compact ? AppTheme.spaceXS : AppTheme.spaceSM) {
            Button {
                if appleMusicPlayback.currentItem != nil {
                    Task { await appleMusicPlayback.playPrevious() }
                } else {
                    player.playPrevious()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil && appleMusicPlayback.currentItem == nil)
            .help(L10n.text("player.previous"))
            .accessibilityLabel(L10n.text("player.previous"))

            Button(action: primaryPlaybackAction) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(compact ? .small : .regular)
            .disabled(
                (appleMusicPlayback.isWorking && !hasLocalPlaybackCandidate)
                    || (!hasLocalPlaybackCandidate && appleMusicPlayback.currentItem == nil)
            )
            .keyboardShortcut(.space, modifiers: [])
            .help(L10n.text(isPlaying ? "player.pause" : "track.play"))
            .accessibilityLabel(L10n.text(isPlaying ? "player.pause" : "track.play"))

            Button {
                if appleMusicPlayback.currentItem != nil {
                    Task { await appleMusicPlayback.playNext() }
                } else {
                    player.playNext()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil && appleMusicPlayback.currentItem == nil)
            .help(L10n.text("player.next"))
            .accessibilityLabel(L10n.text("player.next"))
        }
    }

    private func primaryPlaybackAction() {
        if let selectedTrack = PlaybackStartResolver.selectedTrackToStart(
            currentTrackID: player.currentTrack?.id,
            selectedTrack: library.selectedTrack
        ) {
            if appleMusicPlayback.currentItem != nil {
                appleMusicPlayback.stopForLocalPlayback()
            }
            playSelectedTrack(selectedTrack)
            return
        }

        if player.currentTrack != nil {
            if appleMusicPlayback.currentItem != nil {
                appleMusicPlayback.stopForLocalPlayback()
            }
            player.togglePlayback()
            return
        }

        if let playableTrack {
            if appleMusicPlayback.currentItem != nil {
                appleMusicPlayback.stopForLocalPlayback()
            }
            playSelectedTrack(playableTrack)
            return
        }

        if appleMusicPlayback.currentItem != nil {
            if appleMusicPlayback.isPlaying {
                appleMusicPlayback.pause()
            } else {
                Task { await appleMusicPlayback.resume() }
            }
        }
    }

    private func playSelectedTrack(_ track: Track) {
        let visibleQueue = library.filteredTracks
        player.play(
            track,
            queue: visibleQueue.contains(where: { $0.id == track.id })
                ? visibleQueue : library.tracks
        )
    }

    private var isPlaying: Bool {
        appleMusicPlayback.currentItem != nil
            ? appleMusicPlayback.isPlaying
            : player.isPlaying
    }

    private var playableTrack: Track? {
        library.selectedTrack ?? library.filteredTracks.first ?? library.tracks.first
    }

    private var hasLocalPlaybackCandidate: Bool {
        player.currentTrack != nil || playableTrack != nil
    }
}

struct NowPlayingArtwork: View {
    let track: Track?
    let size: CGFloat

    var body: some View {
        Group {
            if let track {
                ArtworkThumbnail(
                    tracks: [track],
                    subject: .album(name: track.album, artist: track.artist),
                    shape: .roundedRectangle,
                    fallbackSymbol: "waveform",
                    fallbackLetter: String(track.album.prefix(1)).uppercased()
                )
            } else {
                RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                    .fill(AppTheme.raised)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.32, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))
    }
}

struct PlaybackModeMenu: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        Menu {
            ForEach(PlaybackMode.allCases) { mode in
                Button {
                    player.playbackMode = mode
                } label: {
                    Label(L10n.text(mode.localizationKey), systemImage: mode.systemImage)
                }
            }
        } label: {
            Label(
                L10n.text(player.playbackMode.localizationKey),
                systemImage: player.playbackMode.systemImage
            )
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(
            player.playbackMode == .sequential ? AppTheme.secondaryInk : AppTheme.accent
        )
        .help(L10n.text(player.playbackMode.localizationKey))
        .accessibilityLabel(L10n.text("player.mode.title"))
        .accessibilityValue(L10n.text(player.playbackMode.localizationKey))
    }
}

struct PlaybackQueueContextActions: View {
    @EnvironmentObject private var player: PlaybackController
    let tracks: [Track]

    var body: some View {
        Button(L10n.text("player.queue.playNext")) {
            player.enqueueNext(tracks)
        }
        Button(L10n.text("player.queue.playLater")) {
            player.appendToQueue(tracks)
        }
    }
}

struct PlaybackQueueButton: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.text("player.queue.title"))
        .accessibilityLabel(L10n.text("player.queue.title"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PlaybackQueuePopover()
        }
    }
}

private struct PlaybackQueuePopover: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case queue
        case history

        var id: String { rawValue }
        var titleKey: String { "player.\(rawValue).title" }
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @State private var selectedTab: Tab = .queue
    @State private var selectedQueueTrackID: Track.ID?
    @State private var selectedAppleMusicQueueItemIDs: Set<String> = []
    @State private var selectedHistorySessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(selectedTab.titleKey))
                    .font(.headline)
                Spacer()
                if selectedTab == .queue {
                    if appleMusicPlayback.currentItem != nil {
                        Button(L10n.text("player.queue.removeSelected")) {
                            appleMusicPlayback.removeQueueItems(
                                ids: selectedAppleMusicQueueItemIDs
                            )
                            selectedAppleMusicQueueItemIDs.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .disabled(removableAppleMusicSelection.isEmpty)
                        Button(L10n.text("player.queue.clear")) {
                            appleMusicPlayback.clearUpcomingQueue()
                            selectedAppleMusicQueueItemIDs.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .disabled(appleMusicPlayback.queueItems.count <= 1)
                    } else {
                        Button(L10n.text("player.queue.undo")) {
                            player.undoLastQueueEdit()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!player.canUndoQueueEdit)
                        Button(L10n.text("player.queue.clear")) {
                            player.clearUpcomingQueue()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button(L10n.text("player.history.clear")) {
                        Task { await library.clearPlaybackHistory() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.playbackEvents.isEmpty)
                }
            }
            .padding(AppTheme.spaceMD)

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(L10n.text(tab.titleKey)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, AppTheme.spaceMD)
            .padding(.bottom, AppTheme.spaceSM)

            Divider()

            if selectedTab == .queue {
                queueContent
            } else {
                historyContent
            }
        }
        .frame(width: 430)
        .background(AppTheme.surface)
    }

    @ViewBuilder
    private var queueContent: some View {
        if appleMusicPlayback.currentItem != nil {
            appleMusicQueueContent
        } else if player.queuedTracks.isEmpty {
            ContentUnavailableView(
                L10n.text("player.queue.empty"),
                systemImage: "text.line.first.and.arrowtriangle.forward"
            )
            .frame(height: 310)
        } else {
            List(selection: $selectedQueueTrackID) {
                ForEach(Array(player.queuedTracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: player.currentTrack?.id == track.id
                              ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(player.currentTrack?.id == track.id
                                             ? AppTheme.accent : AppTheme.secondaryInk)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text("\(track.artist) — \(track.album)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(DurationFormatter.string(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                        queueButtons(track: track, index: index)
                    }
                    .contentShape(Rectangle())
                    .tag(track.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectedQueueTrackID = track.id
                            library.selectedTrackID = track.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedQueueTrackID = track.id
                            library.selectedTrackID = track.id
                            player.play(track)
                        }
                    )
                }
                .onMove(perform: player.moveInQueue)
            }
            .listStyle(.inset)
            .frame(height: 310)
        }
    }

    @ViewBuilder
    private var appleMusicQueueContent: some View {
        if appleMusicPlayback.queueItems.isEmpty {
            ContentUnavailableView(
                L10n.text("player.queue.loadingAppleMusic"),
                systemImage: "apple.logo"
            )
            .frame(height: 310)
        } else {
            List(selection: $selectedAppleMusicQueueItemIDs) {
                ForEach(Array(appleMusicPlayback.queueItems.enumerated()), id: \.element.id) {
                    index, item in
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: appleMusicPlayback.currentQueueItem?.id == item.id
                            ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(appleMusicPlayback.currentQueueItem?.id == item.id
                                ? AppTheme.accent : AppTheme.secondaryInk)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer()
                        if item.duration > 0 {
                            Text(DurationFormatter.string(item.duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryInk)
                        }
                        appleMusicQueueButtons(item: item, index: index)
                    }
                    .contentShape(Rectangle())
                    .tag(item.id)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedAppleMusicQueueItemIDs = [item.id]
                            Task { await appleMusicPlayback.playQueueItem(id: item.id) }
                        }
                    )
                    .contextMenu {
                        Button(L10n.text("player.queue.remove")) {
                            appleMusicPlayback.removeQueueItems(ids: [item.id])
                            selectedAppleMusicQueueItemIDs.remove(item.id)
                        }
                        .disabled(appleMusicPlayback.currentQueueItem?.id == item.id)
                    }
                }
                .onMove(perform: appleMusicPlayback.moveQueueItems)
            }
            .listStyle(.inset)
            .frame(height: 310)
            .onChange(of: appleMusicPlayback.queueItems) { _, items in
                selectedAppleMusicQueueItemIDs.formIntersection(Set(items.map(\.id)))
            }
        }
    }

    private var removableAppleMusicSelection: Set<String> {
        selectedAppleMusicQueueItemIDs.subtracting(
            appleMusicPlayback.currentQueueItem.map { [$0.id] } ?? []
        )
    }

    @ViewBuilder
    private var historyContent: some View {
        let items = PlaybackHistoryResolver.items(
            events: library.playbackEvents,
            tracks: library.tracks
        )
        if items.isEmpty {
            ContentUnavailableView(
                L10n.text("player.history.empty"),
                systemImage: "clock.arrow.circlepath"
            )
            .frame(height: 310)
        } else {
            List(selection: $selectedHistorySessionID) {
                ForEach(items) { item in
                    HStack(spacing: AppTheme.spaceSM) {
                    Image(systemName: historySymbol(item.event.kind))
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.track.title).lineLimit(1)
                        Text("\(item.track.artist) — \(item.track.album)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.text(item.event.kind.titleKey))
                            .font(.caption)
                        Text(item.event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                    }
                    .contentShape(Rectangle())
                    .tag(item.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectedHistorySessionID = item.id
                            library.selectedTrackID = item.track.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedHistorySessionID = item.id
                            library.selectedTrackID = item.track.id
                            player.play(item.track)
                        }
                    )
                }
            }
            .listStyle(.inset)
            .frame(height: 310)
        }
    }

    private func historySymbol(_ kind: PlaybackEvent.Kind) -> String {
        switch kind {
        case .started: "play.circle"
        case .completed: "checkmark.circle"
        case .skipped: "forward.circle"
        }
    }

    @ViewBuilder
    private func queueButtons(track: Track, index: Int) -> some View {
        HStack(spacing: 2) {
            Button { player.moveInQueue(track, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L10n.text("player.queue.moveUp"))

            Button { player.moveInQueue(track, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == player.queuedTracks.count - 1)
            .help(L10n.text("player.queue.moveDown"))

            Button { player.removeFromQueue(track) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack?.id == track.id)
            .help(L10n.text("player.queue.remove"))
        }
    }

    @ViewBuilder
    private func appleMusicQueueButtons(item: AppleMusicQueueItem, index: Int) -> some View {
        HStack(spacing: 2) {
            Button { appleMusicPlayback.moveQueueItem(id: item.id, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(
                index <= 1 || appleMusicPlayback.currentQueueItem?.id == item.id
            )
            .help(L10n.text("player.queue.moveUp"))

            Button { appleMusicPlayback.moveQueueItem(id: item.id, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(
                index == appleMusicPlayback.queueItems.count - 1
                    || appleMusicPlayback.currentQueueItem?.id == item.id
            )
            .help(L10n.text("player.queue.moveDown"))

            Button {
                appleMusicPlayback.removeQueueItems(ids: [item.id])
                selectedAppleMusicQueueItemIDs.remove(item.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(appleMusicPlayback.currentQueueItem?.id == item.id)
            .help(L10n.text("player.queue.remove"))
        }
    }
}

enum DurationFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
