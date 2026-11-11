import SwiftUI
import Observation

// Native adaptation of Synth EffectsPatchView / PatchNodeCard, whose port and
// cable presentation derives from UNGE. One geometry definition drives both.
enum RoutingNodeLayout {
    static let width: CGFloat = 248
    static let waveformHeight: CGFloat = 148
    static let canvasInset: CGFloat = 48
    // Keep saved document coordinates intact; enlarge the presentation spacing
    // together with the cards so existing columns do not overlap.
    static let spacingScale: CGFloat = 1.3
    static func origin(_ node: AudioRoutingNode) -> CGPoint {
        CGPoint(x: canvasInset + node.x * spacingScale,
                y: canvasInset + node.y * spacingScale)
    }
    static func portY(_ name: String) -> CGFloat { name == "b" ? 118 : 78 }
    static func height(_ node: AudioRoutingNode) -> CGFloat {
        switch node.kind {
        case .delay: 280
        case .mixer: 228
        case .gain, .lowpass: 184
        case .application: 308
        case .recorder: 224
        case .device: 264
        case .meter: 144
        case .waveform: 134 + waveformHeight
        case .equalizer: 238
        case .compressor: 382
        case .limiter: 254
        }
    }
    static func cable(from a: CGPoint, to b: CGPoint) -> Path {
        let bend = min(120, max(55, abs(b.x-a.x)*0.45))
        var path = Path(); path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x+bend, y: a.y), control2: CGPoint(x: b.x-bend, y: b.y))
        return path
    }
    static func target(from source: AudioRoutingPort, at point: CGPoint,
                       in document: AudioRoutingDocument, radius: CGFloat) -> AudioRoutingPort? {
        var nearest: (port: AudioRoutingPort, distance: CGFloat)?
        for node in document.nodes where node.id != source.nodeID {
            let names = source.isOutput ? node.kind.inputs : node.kind.hasOutput ? ["out"] : []
            for name in names {
                let candidate = AudioRoutingPort(nodeID: node.id, isOutput: !source.isOutput, name: name)
                let center = port(node, output: candidate.isOutput, name: name)
                let distance = hypot(point.x-center.x, point.y-center.y)
                if distance <= radius && (nearest == nil || distance < nearest!.distance) { nearest = (candidate, distance) }
            }
        }
        return nearest?.port
    }
    static func port(_ node: AudioRoutingNode, output: Bool, name: String = "in", offset: CGSize = .zero) -> CGPoint {
        CGPoint(x: origin(node).x + (output ? width : 0) + offset.width,
                y: origin(node).y + portY(name) + offset.height)
    }
}
struct AudioRoutingGraphView<SourceControls: View, RecorderControls: View>: View {
    @ObservedObject var store: AudioRoutingStore
    let levels: ApplicationAudioLevels
    var outputs: [ApplicationAudioOutput] = []
    var sessionError: String?
    var refreshDevices: () -> Void
    var showNodeSettings: (UUID) -> Void
    @ViewBuilder var sourceControls: () -> SourceControls
    @ViewBuilder var recorderControls: () -> RecorderControls
    @State private var interaction = AudioRoutingInteraction()
    @State private var showsRoutingHelp = false
    @State private var committedZoom: CGFloat = 1
    // GestureState automatically discards an interrupted pinch, so the next
    // gesture starts from the last committed button/pinch scale.
    @GestureState private var pinchMagnification: CGFloat = 1
    private var zoom: CGFloat { clampedZoom(committedZoom * pinchMagnification) }
    @Namespace private var canvasCoordinateSpace

    var body: some View {
        let _ = AudioRoutingRenderDiagnostics.count("graphBody")
        GeometryReader { viewport in
            let width = max(viewport.size.width / zoom, store.document.nodes.map {
                RoutingNodeLayout.origin($0).x + RoutingNodeLayout.width + RoutingNodeLayout.canvasInset
            }.max() ?? 0)
            let height = max(viewport.size.height / zoom, store.document.nodes.map {
                RoutingNodeLayout.origin($0).y + RoutingNodeLayout.height($0) + RoutingNodeLayout.canvasInset
            }.max() ?? 0)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(AppTheme.canvas)
                        .frame(width: width, height: height)
                        .contextMenu { stageMenu }
                        .accessibilityHidden(true)
                    AudioRoutingGrid(size: CGSize(width: width, height: height)).equatable()
                    AudioRoutingCables(document: store.document, interaction: interaction, store: store,
                                       isLocked: store.isLocked, size: CGSize(width: width, height: height), zoom: zoom)
                    ForEach(store.document.nodes) { node in
                        AudioRoutingNodePlacement(node: node, interaction: interaction,
                            content: AudioRoutingNodeView(store: store, document: store.document,
                                node: node, isLocked: store.isLocked, interaction: interaction,
                                canvasCoordinateSpace: canvasCoordinateSpace, zoom: zoom,
                                levels: levels, outputs: outputs, refreshDevices: refreshDevices, showNodeSettings: showNodeSettings,
                                sourceControls: sourceControls, recorderControls: recorderControls,
                                stageActions: { stageMenu }))
                    }
                }
                .frame(width: width, height: height)
                // Measure in the stationary, unscaled canvas, not in a card
                // whose offset changes in response to this same gesture.
                .coordinateSpace(name: canvasCoordinateSpace)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
            }
            .background(AppTheme.canvas)
            .clipped()
            .accessibilityIdentifier("capture.routing.canvas")
            .simultaneousGesture(pinchGesture,
                including: interaction.dragging == nil && interaction.cableDrag == nil ? .all : .subviews)
            .overlay(alignment: .bottomLeading) {
                if let message = store.error ?? sessionError ?? (store.hasCompleteRoute ? nil : L10n.text("routing.error.disconnected")) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).lineLimit(3).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(AppTheme.canvas)
        .alert(L10n.text("routing.helpTitle"), isPresented: $showsRoutingHelp) {
            Button(L10n.text("recording.done"), role: .cancel) {}
        } message: {
            Text(L10n.text("routing.help"))
        }
        .onExitCommand {
            let wasDragging = interaction.cableDrag != nil
            interaction.cancelCable()
            interaction.cancelledPortDrag = wasDragging
        }
        .onDisappear { interaction.cancel() }
        .onChange(of: store.isLocked) { _, locked in
            if locked { interaction.cancelCable() }
        }
        .onChange(of: store.editor.revision) { _, _ in
            if interaction.dragging == nil { interaction.cancelCable() }
        }
    }
    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(1.5, max(0.5, value))
    }
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchMagnification) { value, scale, transaction in
                guard value.magnification.isFinite, value.magnification > 0 else { return }
                transaction.animation = nil
                scale = value.magnification
            }
            .onEnded { value in
                guard interaction.dragging == nil, interaction.cableDrag == nil,
                      value.magnification.isFinite, value.magnification > 0 else { return }
                committedZoom = clampedZoom(committedZoom * value.magnification)
            }
    }
    @ViewBuilder private var stageMenu: some View {
        Menu(L10n.text("routing.add")) {
            ForEach(AudioRoutingKind.allCases.filter { $0 != .application }) { kind in
                Button { add(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    .disabled(kind.isSink && store.document.nodes.contains { $0.kind == kind })
            }
        }
        .disabled(store.isLocked || store.document.nodes.count >= 16)
        Menu(L10n.text("routing.templates")) {
            Button(L10n.text("routing.recordMonitorTemplate")) { store.perform(.replace(.recordingAndMonitoring)) }
            Button(L10n.text("routing.monitorTemplate")) { store.perform(.replace(.monitoring)) }
            Button(L10n.text("routing.serial")) { store.perform(.replace(.initial)) }
            Button(L10n.text("routing.parallel")) { store.perform(.replace(.parallel)) }
        }
        .disabled(store.isLocked)
        Divider()
        Button(L10n.text("routing.undo")) { store.undo() }
            .disabled(store.isLocked || !store.editor.canUndo)
        Button(L10n.text("routing.redo")) { store.redo() }
            .disabled(store.isLocked || !store.editor.canRedo)
        Divider()
        Button(L10n.text("routing.zoomIn")) { committedZoom = clampedZoom(zoom + 0.125) }
            .disabled(zoom >= 1.5)
        Button(L10n.text("routing.zoomOut")) { committedZoom = clampedZoom(zoom - 0.125) }
            .disabled(zoom <= 0.5)
        Button(L10n.text("routing.helpTitle")) { showsRoutingHelp = true }
    }
    private func add(_ kind: AudioRoutingKind) {
        // Put the second destination below the first so the split stays visible
        // instead of drawing the monitoring cable behind the recording card.
        var positions: [CGPoint] = []
        if kind.isSink, let other = store.document.nodes.first(where: { $0.kind.isSink && $0.kind != kind }) {
            positions.append(CGPoint(x: other.x,y: other.y+280))
            if other.y >= 340 { positions.append(CGPoint(x: other.x,y: other.y-280)) }
        }
        // Fill nearby rows before extending the graph farther to the right.
        for diagonal in 0..<13 {
            for row in 0..<5 {
                let column = diagonal - row
                guard (0..<9).contains(column) else { continue }
                positions.append(CGPoint(x: Double(column) * 240 + 24, y: Double(row) * 280 + 60))
            }
        }
        for position in positions where position.y <= 1400 {
            let node = AudioRoutingNode(kind: kind,x: position.x,y: position.y)
            let rect = CGRect(x: RoutingNodeLayout.origin(node).x-16,y: RoutingNodeLayout.origin(node).y-16,
                              width: RoutingNodeLayout.width+32,height: RoutingNodeLayout.height(node)+32)
            if store.document.nodes.allSatisfy({
                !rect.intersects(CGRect(x: RoutingNodeLayout.origin($0).x,y: RoutingNodeLayout.origin($0).y,
                                       width: RoutingNodeLayout.width,height: RoutingNodeLayout.height($0)))
            }) {
                store.perform(store.document.addingNode(node)); interaction.selected = node.id; return
            }
        }
    }


}

@MainActor @Observable
private final class AudioRoutingInteraction {
    var selected: UUID?
    var cableSource: UUID?
    var cableRevision: UInt64?
    var cableDrag: AudioRoutingPort?
    var cablePoint: CGPoint?
    var cableTarget: AudioRoutingPort?
    var cancelledPortDrag = false
    func cancelCable() {
        cableSource = nil; cableRevision = nil; cableDrag = nil; cablePoint = nil; cableTarget = nil
        cancelledPortDrag = false
    }
    var dragging: UUID?
    var dragOffset = CGSize.zero
    var dragRevision: UInt64?
    func offset(for id: UUID) -> CGSize { dragging == id ? dragOffset : .zero }
    func cancel() { dragging = nil; dragOffset = .zero; dragRevision = nil; cancelCable() }
}

// The background is independent of meters, selection and pointer movement.
private struct AudioRoutingGrid: View, Equatable {
    let size: CGSize
    var body: some View {
        Canvas { context, _ in
            AudioRoutingRenderDiagnostics.count("gridDraw")
            var dots = Path()
            for x in stride(from: CGFloat(12), to: size.width, by: 24) {
                for y in stride(from: CGFloat(12), to: size.height, by: 24) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.2)))
        }.frame(width: size.width, height: size.height).allowsHitTesting(false)
    }
}

private struct AudioRoutingCables: View {
    let document: AudioRoutingDocument
    let interaction: AudioRoutingInteraction
    let store: AudioRoutingStore
    let isLocked: Bool
    let size: CGSize
    let zoom: CGFloat
    var body: some View {
        let moving = interaction.dragging
        let translation = interaction.dragOffset
        let selected = interaction.selected
        let origin = interaction.cableDrag
        let pointer = interaction.cablePoint
        let target = interaction.cableTarget
        let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let paths = document.edges.compactMap { edge -> (edge: AudioRoutingEdge, path: Path)? in
            guard let from = nodes[edge.from], let to = nodes[edge.to] else { return nil }
            return (edge, RoutingNodeLayout.cable(
                from: RoutingNodeLayout.port(from, output: true, offset: from.id == moving ? translation : .zero),
                to: RoutingNodeLayout.port(to, output: false, name: edge.port, offset: to.id == moving ? translation : .zero)))
        }
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                AudioRoutingRenderDiagnostics.count("cableDraw")
                for item in paths {
                    context.stroke(item.path, with: .color(.primary.opacity(selected == item.edge.from || selected == item.edge.to ? 0.8 : 0.35)),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let origin, let pointer, let node = nodes[origin.nodeID] {
                    let start = RoutingNodeLayout.port(node, output: origin.isOutput, name: origin.name)
                    let end = target.flatMap { port in nodes[port.nodeID].map { RoutingNodeLayout.port($0, output: port.isOutput, name: port.name) } } ?? pointer
                    let path = RoutingNodeLayout.cable(from: origin.isOutput ? start : end, to: origin.isOutput ? end : start)
                    context.stroke(path, with: .color(.primary.opacity(0.8)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6,4]))
                }
            }.allowsHitTesting(false)
            // Only the narrow curve is interactive. The rest of the canvas
            // remains available for scrolling and the node controls above it.
            ForEach(paths, id: \.edge.id) { item in
                let hit = item.path.strokedPath(StrokeStyle(lineWidth: 14 / zoom, lineCap: .round))
                hit.fill(Color.clear)
                    .contentShape(hit)
                    .contextMenu {
                        Text(routingEdgeLabel(item.edge, in: document))
                        Button(L10n.text("routing.disconnect")) { store.perform(.disconnect(item.edge.id)) }
                            .disabled(isLocked)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(routingEdgeLabel(item.edge, in: document))
                    .accessibilityAction(named: Text(L10n.text("routing.disconnect"))) {
                        store.perform(.disconnect(item.edge.id))
                    }
            }
        }.frame(width: size.width, height: size.height)
    }
}

private func routingEdgeLabel(_ edge: AudioRoutingEdge, in document: AudioRoutingDocument) -> String {
    let from = document.nodes.first { $0.id == edge.from }?.kind.title ?? ""
    let to = document.nodes.first { $0.id == edge.to }?.kind.title ?? ""
    return "\(from) → \(to) · \(edge.port.uppercased())"
}

private struct AudioRoutingNodePlacement<Content: View>: View {
    let node: AudioRoutingNode
    let interaction: AudioRoutingInteraction
    let content: Content
    var body: some View {
        let offset = interaction.offset(for: node.id)
        content.offset(x: RoutingNodeLayout.origin(node).x + offset.width,
                       y: RoutingNodeLayout.origin(node).y + offset.height)
            .zIndex(interaction.dragging == node.id ? 2 : interaction.selected == node.id ? 1 : 0)
    }
}

private struct AudioRoutingWaveformView: View {
    let levels: ApplicationAudioLevels
    let id: UUID

    var body: some View {
        let pairs = levels.waveforms[id] ?? []
        Canvas { context, size in
            let mid = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: mid))
            baseline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(baseline, with: .color(.secondary.opacity(0.35)))
            var waveform = Path()
            let count = pairs.count / 2
            for index in 0..<count {
                let x = (CGFloat(index) + 0.5) * size.width / CGFloat(count)
                let low = CGFloat(max(-1, pairs[index * 2]))
                let high = CGFloat(min(1, pairs[index * 2 + 1]))
                waveform.move(to: CGPoint(x: x, y: mid * (1 - high)))
                waveform.addLine(to: CGPoint(x: x, y: mid * (1 - low)))
            }
            context.stroke(waveform, with: .color(.primary), lineWidth: 1.25)
        }
        .frame(height: RoutingNodeLayout.waveformHeight)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(L10n.text("routing.node.8"))
    }
}

enum AudioRoutingMeterScale {
    static let greenUpper = Float(pow(10, -6.0 / 20))
    static let yellowUpper = Float(pow(10, -3.0 / 20))
    static func band(for peak: Float) -> Int {
        peak <= greenUpper ? 0 : peak <= yellowUpper ? 1 : 2
    }
}

struct AudioRoutingMeterView: View {
    @Environment(\.colorScheme) private var colorScheme
    let levels: ApplicationAudioLevels
    let id: UUID
    var body: some View {
        let _ = AudioRoutingRenderDiagnostics.count("meterBody")
        let peak = levels.peaks[id] ?? 0
        let clipped = levels.clippedNodes.contains(id)
        let ink: [Color] = colorScheme == .dark ? [.green, .yellow, .red] : [
            Color(red: 0.12, green: 0.45, blue: 0.22),
            Color(red: 0.55, green: 0.36, blue: 0),
            Color(red: 0.75, green: 0.08, blue: 0.15)
        ]
        let value = peak > 0 ? String(format: "%.1f dBFS", 20*log10(peak)) : "−∞ dBFS"
        HStack(spacing: 8) {
            Text(value).font(.body.monospacedDigit())
                .foregroundStyle(peak > 0 ? ink[AudioRoutingMeterScale.band(for: peak)] : Color.secondary)
            Spacer(minLength: 0)
            Button { levels.clearClipping(id) } label: {
                Circle()
                    .fill(clipped ? Color.red : Color.primary.opacity(0.15))
                    .overlay(Circle().strokeBorder(clipped ? Color.red : Color.primary.opacity(0.25), lineWidth: 1))
                    .shadow(color: clipped ? .red.opacity(0.65) : .clear, radius: 3)
                    .frame(width: 10, height: 10).frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("routing.clipHelp"))
            .accessibilityLabel(L10n.text("routing.clipLamp"))
            .accessibilityValue(L10n.text(clipped ? "routing.clipDetected" : "routing.clipClear"))
        }
        Canvas { context, size in
            let ends = [0.0, Double(AudioRoutingMeterScale.greenUpper), Double(AudioRoutingMeterScale.yellowUpper), 1.0]
            let colors: [Color] = [.green, .yellow, .red]
            let level = Double(min(1, max(0, peak)))
            for index in 0..<3 {
                let start = ends[index] * size.width
                let width = (ends[index+1] - ends[index]) * size.width
                let track = CGRect(x: start, y: 0, width: max(0, width-1), height: size.height)
                context.fill(Path(roundedRect: track, cornerRadius: 1), with: .color(colors[index].opacity(0.18)))
                let filled = max(0, min(ends[index+1], level) - ends[index]) * size.width
                if filled > 0 {
                    context.fill(Path(CGRect(x: start, y: 0, width: min(filled, max(0, width-1)), height: size.height)), with: .color(colors[index]))
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel(L10n.text("routing.levelMeter"))
        .accessibilityValue(value)
        .help(L10n.text("routing.levelColorsHelp"))
    }
}

private struct AudioRoutingNodeView<SourceControls: View, RecorderControls: View, StageActions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: AudioRoutingStore
    let document: AudioRoutingDocument
    let node: AudioRoutingNode
    let isLocked: Bool
    let interaction: AudioRoutingInteraction
    let canvasCoordinateSpace: Namespace.ID
    let zoom: CGFloat
    let levels: ApplicationAudioLevels
    let outputs: [ApplicationAudioOutput]
    let refreshDevices: () -> Void
    let showNodeSettings: (UUID) -> Void
    @ViewBuilder var sourceControls: () -> SourceControls
    @ViewBuilder var recorderControls: () -> RecorderControls
    @ViewBuilder var stageActions: () -> StageActions
    private var nodeSurface: Color { Color(white: colorScheme == .dark ? 0.88 : 0.18) }
    private var nodeInk: Color { Color(white: colorScheme == .dark ? 0.12 : 0.96) }
    private var nodeScheme: ColorScheme { colorScheme == .dark ? .light : .dark }
    var body: some View {
        let _ = AudioRoutingRenderDiagnostics.count("cardBody")
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(nodeSurface)
                    .onTapGesture(count: 2) { showNodeSettings(node.id) }
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(interaction.selected == node.id ? 0.75 : 0.18), lineWidth: interaction.selected == node.id ? 2 : 1) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: node.kind.symbol)
                            Text(node.kind.title).font(.body.weight(.semibold)).lineLimit(2).layoutPriority(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { showNodeSettings(node.id) }
                        .onTapGesture { interaction.selected = node.id }
                        .help(L10n.text("routing.doubleClickSettings"))
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(canvasCoordinateSpace))
                            .onChanged { value in
                                if interaction.dragging == nil {
                                    store.finishParameterEdit()
                                    AudioRoutingRenderDiagnostics.begin("drag")
                                    interaction.dragging = node.id
                                    interaction.dragRevision = store.editor.revision
                                    interaction.selected = node.id
                                }
                                interaction.dragOffset = value.translation
                            }.onEnded { value in
                                guard interaction.dragging == node.id else { return }
                                // Mouse-up can contain a newer position than the
                                // last onChanged event. Use that final canvas delta.
                                let x = min(2200, max(0, node.x + value.translation.width / RoutingNodeLayout.spacingScale))
                                let y = min(1400, max(0, node.y + value.translation.height / RoutingNodeLayout.spacingScale))
                                let revision = interaction.dragRevision
                                interaction.cancel()
                                store.perform(.move(node.id, x, y), revision: revision)
                                AudioRoutingRenderDiagnostics.end("drag")
                            })
                        if [.gain, .lowpass, .delay, .equalizer, .compressor, .limiter].contains(node.kind) {
                            Button { store.perform(.bypass(node.id, !node.bypassed)) } label: {
                                Image(systemName: "power").foregroundStyle(node.bypassed ? .secondary : .primary)
                            }
                            .help(L10n.text("routing.bypass"))
                            .accessibilityLabel(L10n.text("routing.bypass"))
                            .accessibilityValue(L10n.text(node.bypassed ? "routing.bypassOn" : "routing.bypassOff"))
                            .disabled(isLocked && !store.canAdjustLive)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(.primary.opacity(0.05))
                    VStack(alignment: .leading, spacing: 8) {
                        if node.kind == .application {
                            sourceControls()
                            AudioRoutingParameterView(node: node, store: store)
                                .help(L10n.text("routing.inputBoostHelp"))
                            AudioRoutingMeterView(levels: levels, id: node.id)
                        } else if node.kind == .device {
                            Picker(L10n.text("routing.device"), selection: Binding(
                                get: { node.deviceUID ?? "" },
                                set: { store.perform(.device(node.id, $0)) })) {
                                Text(L10n.text("routing.chooseDevice")).tag("")
                                if let uid = node.deviceUID, !outputs.contains(where: { $0.id == uid }) {
                                    Text(L10n.text("routing.deviceMissing")).tag(uid)
                                }
                                ForEach(outputs) { Text($0.name).tag($0.id) }
                            }.labelsHidden().disabled(isLocked)
                            HStack {
                                Text(outputs.first { $0.id == node.deviceUID }?.name ?? L10n.text("routing.chooseDevice"))
                                    .font(.body).foregroundStyle(.secondary).lineLimit(2)
                                Spacer(minLength: 0)
                                Button(action: refreshDevices) { Image(systemName: "arrow.clockwise") }
                                    .help(L10n.text("routing.refreshDevices"))
                                    .accessibilityLabel(L10n.text("routing.refreshDevices"))
                                    .disabled(isLocked)
                            }
                            AudioRoutingParameterView(node: node, store: store)
                                .help(L10n.text("routing.monitorVolumeHelp"))
                            AudioRoutingMeterView(levels: levels, id: node.id)
                        } else if node.kind == .recorder {
                            recorderControls()
                        } else if node.kind == .waveform {
                            AudioRoutingWaveformView(levels: levels, id: node.id)
                            AudioRoutingMeterView(levels: levels, id: node.id)
                        } else if node.kind == .limiter {
                            AudioRoutingParameterView(node: node, store: store)
                            AudioRoutingMeterView(levels: levels, id: node.id)
                        } else if node.kind == .meter {
                            AudioRoutingMeterView(levels: levels, id: node.id)
                        } else {
                            AudioRoutingParameterView(node: node, store: store)
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.regular)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .contextMenu { nodeActions }
            ForEach(node.kind.inputs, id: \.self) { port in
                portButton(node, output: false, name: port).position(x: 0, y: RoutingNodeLayout.portY(port))
            }
            if node.kind.hasOutput { portButton(node, output: true, name: "out").position(x: RoutingNodeLayout.width, y: RoutingNodeLayout.portY("out")) }
        }
        .frame(width: RoutingNodeLayout.width, height: RoutingNodeLayout.height(node))
        .font(.body)
        .tint(nodeInk)
        .environment(\.colorScheme, nodeScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.kind.title)
    }
    @ViewBuilder private var nodeActions: some View {
        Button(L10n.text("routing.settings")) { showNodeSettings(node.id) }
        if [.gain, .lowpass, .delay, .equalizer, .compressor, .limiter].contains(node.kind) {
            Button(L10n.text(node.bypassed ? "routing.bypassOff" : "routing.bypass")) {
                store.perform(.bypass(node.id, !node.bypassed))
            }.disabled(isLocked && !store.canAdjustLive)
        }
        let connections = document.edges.filter { $0.to == node.id || $0.from == node.id }
        if !connections.isEmpty {
            Menu(L10n.text("routing.disconnect")) {
                ForEach(connections) { edge in
                    Button(edgeLabel(edge)) { store.perform(.disconnect(edge.id)) }
                }
            }.disabled(isLocked)
        }
        if node.kind != .application && (!node.kind.isSink || document.nodes.filter({ $0.kind.isSink }).count > 1) {
            Button(L10n.text("routing.remove"), role: .destructive) { store.perform(.remove(node.id)) }
                .disabled(isLocked)
        }
        Divider()
        Menu(L10n.text("routing.stageActions")) { stageActions() }
    }
    private func portButton(_ node: AudioRoutingNode, output: Bool, name: String) -> some View {
        let port = AudioRoutingPort(nodeID: node.id, isOutput: output, name: name)
        let connections = port.connections(in: document)
        let selectPort = {
            interaction.selected = node.id
            if output {
                if interaction.cableSource == node.id { interaction.cancelCable() }
                else { interaction.cancelCable(); interaction.cableSource = node.id; interaction.cableRevision = store.editor.revision }
            } else if let source = interaction.cableSource {
                store.perform(.connect(.init(from: source, to: node.id, port: name)), revision: interaction.cableRevision)
                interaction.cancelCable()
            }
        }
        return ZStack {
            Button(action: selectPort) {
                ZStack {
                    Circle().fill(nodeSurface)
                    Circle().strokeBorder(.primary.opacity(interaction.cableTarget == port ? 1 : 0.7), lineWidth: interaction.cableTarget == port ? 3 : 2)
                    if (output && interaction.cableSource == node.id) || interaction.cableDrag == port { Circle().fill(.primary).padding(4) }
                    if name == "a" || name == "b" { Text(name.uppercased()).font(.body.weight(.bold)) }
                }.frame(width: 24, height: 24).padding(4).contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(isLocked)
            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(canvasCoordinateSpace))
                .onChanged { value in
                    guard !store.isLocked, !interaction.cancelledPortDrag else { return }
                    if interaction.cableDrag == nil {
                        interaction.cancelCable(); interaction.cableDrag = port
                        interaction.cableRevision = store.editor.revision
                        interaction.selected = node.id
                    }
                    guard interaction.cableDrag == port else { return }
                    interaction.cablePoint = value.location
                    let target = RoutingNodeLayout.target(from: port, at: value.location, in: document, radius: 18 / zoom)
                    if interaction.cableTarget != target { interaction.cableTarget = target }
                }.onEnded { value in
                    if interaction.cancelledPortDrag { interaction.cancelCable(); return }
                    guard interaction.cableDrag == port else { return }
                    let revision = interaction.cableRevision
                    let target = RoutingNodeLayout.target(from: port, at: value.location, in: document, radius: 18 / zoom)
                    interaction.cancelCable()
                    guard !store.isLocked, let target, let edge = try? port.connection(to: target) else { return }
                    store.perform(.connect(edge), revision: revision)
                })
        }
        .contentShape(Rectangle())
        .contextMenu {
            if output || (interaction.cableSource != nil && connections.isEmpty) {
                Button(L10n.text(output && interaction.cableSource == node.id ? "routing.cancel" : "routing.connectPort"), action: selectPort)
                    .disabled(isLocked)
            }
            if connections.isEmpty && !output && interaction.cableSource == nil {
                Text(L10n.text("routing.noConnections"))
            }
            ForEach(connections) { edge in
                Button(L10n.text("routing.disconnect") + " · " + edgeLabel(edge)) { store.perform(.disconnect(edge.id)) }
                    .disabled(isLocked)
            }
            if connections.count > 1 {
                Divider()
                Button(L10n.text("routing.disconnectAll")) { store.perform(.batch(connections.map { .disconnect($0.id) })) }
                    .disabled(isLocked)
            }
        }
        .help(L10n.format(output ? "routing.outputPort" : "routing.inputPort", node.kind.title, name.uppercased()))
        .accessibilityLabel(L10n.format(output ? "routing.outputPort" : "routing.inputPort", node.kind.title, name.uppercased()))
    }

    private func edgeLabel(_ edge: AudioRoutingEdge) -> String { routingEdgeLabel(edge, in: document) }

}

struct AudioRoutingVerticalSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let finish: () -> Void
    var rackInput: EffectRackInputRouter? = nil
    private let thumbHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.height - thumbHeight
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .top) {
                Capsule().fill(.secondary.opacity(0.35))
                    .frame(width: 3)
                    .padding(.vertical, thumbHeight / 2)
                Capsule().fill(.primary)
                    .frame(width: 14, height: thumbHeight)
                    .offset(y: (1 - fraction) * travel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    setPosition(drag.location.y, travel: travel)
                }
                .onEnded { _ in finish() }, including: rackInput == nil ? .all : .subviews)
            .overlay {
                if let rackInput {
                    KnobInputSurface(isEnabled: isEnabled, input: rackInput,
                                     onPosition: { setPosition($0.y, travel: travel) },
                                     onReset: { setValue(0); finish() },
                                     onStep: { setValue(value + $0); finish() },
                                     onTracking: { if !$0 { finish() } },
                                     onFocus: { _ in })
                }
            }
        }
        .frame(width: 20, height: 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value)) dB")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setValue(value + 1)
            case .decrement: setValue(value - 1)
            @unknown default: return
            }
            finish()
        }
    }

    private func setPosition(_ y: CGFloat, travel: CGFloat) {
        let fraction = min(1, max(0, 1 - (y - thumbHeight / 2) / travel))
        setValue(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    private func setValue(_ next: Double) {
        let stepped = min(range.upperBound, max(range.lowerBound, next.rounded()))
        if stepped != value { value = stepped }
    }
}

struct AudioRoutingParameterView: View {
    let node: AudioRoutingNode
    @ObservedObject var store: AudioRoutingStore
    @State private var parameters: [Double]
    init(node: AudioRoutingNode, store: AudioRoutingStore) {
        self.node = node; self.store = store
        _parameters = State(initialValue: node.parameters)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.kind == .equalizer {
                HStack(spacing: 0) {
                    ForEach(AudioRoutingKind.equalizerBandLabels.indices, id: \.self) { index in
                        let label = AudioRoutingKind.equalizerBandLabels[index]
                        VStack(spacing: 4) {
                            Text(parameters[index].formatted(.number.precision(.fractionLength(0))))
                                .monospacedDigit()
                            AudioRoutingVerticalSlider(
                                value: Binding(get: { parameters[index] }, set: { value in
                                    var next = parameters
                                    next[index] = value
                                    if !store.canAdjustLive || store.previewParameters(node.id, next) { parameters = next }
                                }),
                                range: node.kind.ranges[index],
                                label: label + " Hz",
                                finish: store.finishParameterEdit
                            )
                            Text(label).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .font(.system(size: 9))
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ForEach(node.kind.ranges.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(L10n.text(node.kind.parameterKeys[index])).lineLimit(2)
                            Spacer(minLength: 2)
                            Text(node.kind == .device ? parameters[index].formatted(.percent.precision(.fractionLength(0))) : parameters[index].formatted(.number.precision(.fractionLength(0...2))) + (node.kind == .application ? "×" : ""))
                                .monospacedDigit().fixedSize()
                        }.font(.body)
                        let binding = Binding(get: { parameters[index] }, set: { value in
                            var next = parameters; next[index] = value
                            if !store.canAdjustLive || store.previewParameters(node.id, next) { parameters = next }
                        })
                        let editingChanged: (Bool) -> Void = { editing in
                            if !editing {
                                if [.application, .device].contains(node.kind) && !store.canAdjustLive && parameters != node.parameters {
                                    store.perform(.parameters(node.id, parameters))
                                } else { store.finishParameterEdit() }
                            }
                        }
                        Group {
                            if node.kind == .application {
                                Slider(value: binding, in: node.kind.ranges[index], step: 1, onEditingChanged: editingChanged)
                            } else {
                                Slider(value: binding, in: node.kind.ranges[index], onEditingChanged: editingChanged)
                            }
                        }
                        .accessibilityLabel(node.kind.title + " · " + L10n.text(node.kind.parameterKeys[index]))
                    }
                }
            }
            if !store.canAdjustLive && ![.application, .device].contains(node.kind) {
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.text("routing.apply")) {
                        store.perform(.parameters(node.id, parameters))
                    }.disabled(parameters == node.parameters)
                }
            }
        }
        .disabled(store.isLocked && !store.canAdjustLive)
        .onDisappear { store.finishParameterEdit() }
        // Parameter changes (including Undo) supersede a local draft. Unrelated
        // node moves and edits don't discard another node's unsaved slider value.
        .onChange(of: node.parameters) { _, value in parameters = value }
        .onChange(of: store.isLocked) { _, locked in if locked { parameters = node.parameters } }
    }
}

// Opt-in development counters; never active in release builds or the audio IO.
enum AudioRoutingRenderDiagnostics {
    #if DEBUG
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
        var started: Date?
        var phase = "session"
        let enabled = ProcessInfo.processInfo.environment["ONGAKU_ROUTING_DIAGNOSTICS"] == "1"
    }
    private static let state = State()
    #endif
    static func count(_ name: String) {
        #if DEBUG
        guard state.enabled else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        if state.started != nil { state.counts[name, default: 0] += 1 }
        #endif
    }
    static func begin(_ phase: String = "session") {
        #if DEBUG
        guard state.enabled else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        if phase == "drag", state.started != nil, state.phase == "session" { return }
        state.counts = [:]; state.started = Date(); state.phase = phase
        #endif
    }
    static func end(_ phase: String = "session") {
        #if DEBUG
        guard state.enabled else { return }
        state.lock.lock()
        guard state.started != nil, state.phase == phase else { state.lock.unlock(); return }
        let elapsed = state.started.map { Date().timeIntervalSince($0) } ?? 0
        let counts = state.counts; state.started = nil
        state.lock.unlock()
        let report: [String: Any] = ["phase": phase, "seconds": elapsed, "counts": counts]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { NSLog("Ongaku routing render: %@", text) }
        #endif
    }
}
