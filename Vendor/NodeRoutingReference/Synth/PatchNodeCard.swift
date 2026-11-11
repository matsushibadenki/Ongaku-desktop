import SwiftUI

// Native adaptation of UNGE scene.rs / theme.rs node chrome (MIT).
// Shared anchors are used by ports, cables and drag previews. See Vendor/UNGE.
enum PatchNodeLayout {
    static let width:CGFloat=224
    static func height(_ kind:EffectKind)->CGFloat { kind == .mixer ? 160:144 }
    static func port(output:Bool,name:String="out")->CGPoint {
        CGPoint(x:output ? width-12:12,y:name=="b" ? 116:84)
    }
    static func shortName(_ kind:EffectKind)->String {
        ["SYNTH/05","DIMENSION","SKY","TIME","ECHO PEDAL","RING / 102","STUDIO","MIX / A + B","STEREO OUT"][kind.rawValue]
    }
}

extension EffectKind {
    // UNGE role accents stay distinct from the darker effect-enclosure finishes.
    var patchTone:Color {
        switch self {
        case .synth:return Color(red:0.37,green:0.84,blue:0.72)
        case .dimension:return Color(red:0.71,green:0.62,blue:0.98)
        case .sky:return Color(red:0.43,green:0.76,blue:0.92)
        case .time:return Color(red:0.95,green:0.74,blue:0.41)
        case .pedal:return Color(red:0.57,green:0.82,blue:0.59)
        case .ring:return Color(red:0.93,green:0.55,blue:0.63)
        case .studio:return Color(red:0.58,green:0.72,blue:0.90)
        case .mixer:return Color(red:0.78,green:0.83,blue:0.49)
        case .output:return Color(red:0.46,green:0.82,blue:0.76)
        }
    }
}

struct PatchNodeCard:View {
    let node:FXNode
    let selected:Bool
    let select:()->Void
    let edit:()->Void
    let bypass:()->Void
    let moving:(CGSize)->Void
    let moved:(CGSize)->Void
    @State private var hovered=false
    private var effect:Bool { (1...6).contains(node.id) }
    private var engaged:Bool { !effect || node.settings.enabled }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                HStack(spacing:7) {
                    Image(systemName:node.kind.symbol).font(.system(size:12,weight:.semibold))
                        .foregroundStyle(node.kind.patchTone).frame(width:24,height:24)
                        .background(node.kind.patchTone.opacity(0.16),in:RoundedRectangle(cornerRadius:5))
                    Text(PatchNodeLayout.shortName(node.kind)).font(InstrumentFinish.legend(11)).lineLimit(1)
                    Spacer(minLength:0)
                    Image(systemName:"line.3.horizontal").font(.system(size:8)).foregroundStyle(InstrumentFinish.muted.opacity(0.55))
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:4)
                    .onChanged { select();moving($0.translation) }.onEnded { moved($0.translation) })
                if effect {
                    Button(action:bypass) {
                        Image(systemName:"power").font(.system(size:10,weight:.bold))
                            .foregroundStyle(engaged ? node.kind.patchTone:InstrumentFinish.muted)
                            .frame(width:26,height:28)
                    }.buttonStyle(.plain)
                        .help(fxText("Engage / bypass","有効／バイパス","启用／旁通"))
                        .accessibilityLabel(node.kind.title+" "+fxText("Bypass","バイパス","旁通"))
                        .accessibilityValue(engaged ? fxText("Engaged","有効","启用"):fxText("Bypassed","バイパス","旁通"))
                }
            }.padding(.horizontal,10).frame(height:36)
                .background(node.kind.patchTone.opacity(engaged ? 0.12:0.055))
                .overlay(alignment:.top) { Capsule().fill(node.kind.patchTone.opacity(engaged ? 0.9:0.4)).frame(height:2).padding(.horizontal,12).padding(.top,1) }
            Rectangle().fill(InstrumentFinish.metalEdge.opacity(0.6)).frame(height:1)
            HStack(spacing:6) {
                Circle().fill(engaged ? node.kind.patchTone:InstrumentFinish.muted.opacity(0.4)).frame(width:4,height:4)
                Text(node.kind.modes[node.settings.mode]).font(InstrumentFinish.legend(8)).lineLimit(1)
                    .foregroundStyle(InstrumentFinish.muted)
                Spacer(minLength:0)
                if effect && !engaged { Image(systemName:"arrow.right").font(.system(size:8)).foregroundStyle(InstrumentFinish.muted) }
            }.padding(.horizontal,13).padding(.top,8)
            Spacer(minLength:0)
            if node.kind != .mixer {
                PatchNodeSignature(node:node).frame(height:33).padding(.horizontal,56).opacity(engaged ? 0.8:0.32)
                    .help(fxText("Processing symbol · not a level meter","処理のシンボル（音量メーターではありません）","处理示意图，并非电平表"))
                Spacer(minLength:0)
                HStack(spacing:8) {
                    if let control=node.kind.controls.first,let value=node.settings.values.first {
                        Text(control.label).font(InstrumentFinish.legend(7)).foregroundStyle(InstrumentFinish.muted)
                        Text(control.display(value)).font(InstrumentFinish.legend(9)).monospacedDigit()
                    } else {
                        Image(systemName:node.kind == .synth ? "waveform":"hifispeaker.2").font(.system(size:9))
                        Text("STEREO").font(InstrumentFinish.legend(8)).foregroundStyle(InstrumentFinish.muted)
                    }
                    Spacer(minLength:0)
                    if effect {
                        Button(action:edit) { Image(systemName:"slider.horizontal.3").font(.system(size:11)).frame(width:28,height:28) }
                            .buttonStyle(.plain).help(fxText("Edit effect","エフェクトを編集","编辑效果"))
                            .accessibilityLabel(node.kind.title+" "+fxText("Edit","編集","编辑"))
                    }
                }.padding(.horizontal,13).frame(height:30)
            } else { Spacer(minLength:0).frame(height:76) }
        }
        .frame(width:PatchNodeLayout.width,height:PatchNodeLayout.height(node.kind))
        .background(LinearGradient(colors:[InstrumentFinish.metal,InstrumentFinish.recess.opacity(0.9)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:10))
        .clipShape(RoundedRectangle(cornerRadius:10))
        .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(selected ? node.kind.patchTone:InstrumentFinish.metalEdge.opacity(hovered ? 1:0.8),lineWidth:selected ? 2:1) }
        .overlay { if selected { RoundedRectangle(cornerRadius:13).strokeBorder(node.kind.patchTone.opacity(0.22),lineWidth:3).padding(-3).allowsHitTesting(false) } }
        .shadow(color:.black.opacity(0.5),radius:7,y:4)
        .contentShape(RoundedRectangle(cornerRadius:10)).onTapGesture(perform:select).onHover { hovered=$0 }
    }
}

/// Static processing glyphs, intentionally not signal meters or DSP response plots.
private struct PatchNodeSignature:View {
    let node:FXNode
    var body:some View {
        Canvas { context,size in
            let w=size.width,h=size.height,mid=h/2
            var base=Path();base.move(to:CGPoint(x:0,y:mid));base.addLine(to:CGPoint(x:w,y:mid))
            context.stroke(base,with:.color(InstrumentFinish.metalEdge),lineWidth:0.7)
            var path=Path()
            for i in 0...80 {
                let t=Double(i)/80,x=CGFloat(t)*w
                let wave:Double
                switch node.kind {
                case .synth:wave=(t*3-floor(t*3))*2-1
                case .dimension,.studio:wave=sin(t*4*Double.pi)*0.65
                case .sky:wave=sin(t*11*Double.pi)*exp(-t*2.5)
                case .time,.pedal:wave=t.truncatingRemainder(dividingBy:0.22)<0.035 ? -exp(-t*1.8):0
                case .ring:wave=sin(t*4*Double.pi)*sin(t*15*Double.pi)
                case .output:wave=sin(t*4*Double.pi)*0.6
                case .mixer:wave=0
                }
                let point=CGPoint(x:x,y:mid-CGFloat(wave)*h*0.36)
                if i==0 { path.move(to:point) } else { path.addLine(to:point) }
            }
            context.stroke(path,with:.color(node.kind.patchTone),style:StrokeStyle(lineWidth:1.4,lineCap:.round,lineJoin:.round))
            if node.kind == .dimension || node.kind == .studio {
                context.translateBy(x:0,y:4);context.stroke(path,with:.color(node.kind.patchTone.opacity(0.35)),lineWidth:1)
            }
        }.accessibilityHidden(true)
    }
}
