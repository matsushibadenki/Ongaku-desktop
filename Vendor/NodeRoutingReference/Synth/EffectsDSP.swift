import Foundation

/// Windowed-sinc fractional-delay kernels, prepared before audio rendering.
/// Read speeds above unity lower the cutoff before time compression can fold.
enum FXDelayKernels {
    static let speeds: [Float] = [1,1.5,2,3,4,6,8,12,24,48]
    static let phases=256, count=32
    static let coefficients: [Float] = {
        var result=[Float](repeating:0,count:speeds.count*(phases+1)*count)
        for bank in speeds.indices {
            let cutoff=0.45/Double(speeds[bank])
            for phase in 0...phases {
                let fraction=Double(phase)/Double(phases)
                let base=(bank*(phases+1)+phase)*count
                var sum: Double=0
                for tap in 0..<count {
                    let x=Double(tap-15)-fraction
                    let sinc=abs(x)<1e-12 ? 2*cutoff : sin(2 * Double.pi*cutoff*x)/(Double.pi*x)
                    let window=0.42+0.5*cos(Double.pi*x/16)+0.08*cos(2 * Double.pi*x/16)
                    let value=sinc*window
                    result[base+tap]=Float(value); sum += value
                }
                for tap in 0..<count { result[base+tap] /= Float(sum) }
            }
        }
        return result
    }()
}

/// Fixed-capacity stereo storage; allocated before the render callback starts.
final class FXStereoLine {
    private var samples: [SIMD2<Float>]
    private var cursor = 0
    init(capacity: Int) { samples=Array(repeating:.zero,count:max(40,capacity)) }
    func readBandlimited(_ delay: Float,speed: Float) -> SIMD2<Float> {
        let d=min(Float(samples.count-18),max(17,delay))
        var position=Float(cursor)-d
        if position<0 { position += Float(samples.count) }
        let index=Int(position), fraction=position-Float(index)
        let phasePosition=fraction*Float(FXDelayKernels.phases)
        let phase=min(FXDelayKernels.phases-1,Int(phasePosition)), phaseMix=phasePosition-Float(phase)
        let rate=min(48,max(1,abs(speed)))
        var bank=0
        while bank<FXDelayKernels.speeds.count-2 && rate>FXDelayKernels.speeds[bank+1] { bank += 1 }
        let bankMix=(rate-FXDelayKernels.speeds[bank])/(FXDelayKernels.speeds[bank+1]-FXDelayKernels.speeds[bank])
        let base=(bank*(FXDelayKernels.phases+1)+phase)*FXDelayKernels.count
        let next=base+(FXDelayKernels.phases+1)*FXDelayKernels.count
        var result=SIMD2<Float>.zero
        var sampleIndex=index-15
        if sampleIndex<0 { sampleIndex += samples.count }
        let kernels=FXDelayKernels.coefficients
        for tap in 0..<FXDelayKernels.count {
            let a=kernels[base+tap]*(1-phaseMix)+kernels[base+32+tap]*phaseMix
            let b=kernels[next+tap]*(1-phaseMix)+kernels[next+32+tap]*phaseMix
            result += samples[sampleIndex]*(a+(b-a)*bankMix)
            sampleIndex += 1
            if sampleIndex == samples.count { sampleIndex=0 }
        }
        return result
    }
    func read(_ delay: Float) -> SIMD2<Float> {
        let d=min(Float(samples.count-3),max(1,delay))
        var position=Float(cursor)-d
        if position < 0 { position += Float(samples.count) }
        if position >= Float(samples.count) { position=0 }
        let index=Int(position), fraction=position-Float(index)
        return samples[index]*(1-fraction)+samples[(index+1)%samples.count]*fraction
    }
    func write(_ value: SIMD2<Float>) { samples[cursor]=value; cursor=(cursor+1)%samples.count }
    func reset() {
        for i in samples.indices { samples[i] = .zero };cursor=0
    }
}

/// Fixed 4x polyphase interpolation / FIR decimation around the nonlinear ring.
/// 97-tap Blackman-windowed sinc, unity DC, 24 host samples total latency.
/// Storage and coefficients are prepared off the audio thread.
final class FXRingOversampler {
    static let latency = 24
    private var input=[SIMD2<Float>](repeating:.zero,count:32)
    private var output=[SIMD2<Float>](repeating:.zero,count:128)
    private var taps=[Float](repeating:0,count:97)
    private var inputCursor=0, outputCursor=0
    init() {
        var sum: Float=0
        for i in 0..<97 {
            let x=Double(i-48), cutoff=0.1125
            let sinc=x == 0 ? 2*cutoff : sin(2 * Double.pi*cutoff*x)/(Double.pi*x)
            let window=0.42-0.5*cos(2 * Double.pi*Double(i)/96)+0.08*cos(4 * Double.pi*Double(i)/96)
            taps[i]=Float(sinc*window); sum += taps[i]
        }
        for i in taps.indices { taps[i] /= sum }
    }
    func reset() {
        for i in input.indices { input[i] = .zero }
        for i in output.indices { output[i] = .zero }
        inputCursor=0;outputCursor=0
    }
    var alignedDry: SIMD2<Float> { input[(inputCursor-Self.latency)&31] }
    func process(_ sample: SIMD2<Float>,carrier: inout Float,step: Float,drive: Float) -> SIMD2<Float> {
        inputCursor=(inputCursor+1)&31
        input[inputCursor]=sample
        let normalization=tanhf(drive)
        for phase in 0..<4 {
            var up=SIMD2<Float>.zero
            var tap=phase, age=0
            while tap<97 {
                up += input[(inputCursor-age)&31]*(taps[tap]*4)
                tap += 4; age += 1
            }
            carrier += step/4; carrier -= floorf(carrier)
            let shaped=SIMD2(tanhf(up.x*drive),tanhf(up.y*drive))/normalization
            outputCursor=(outputCursor+1)&127
            output[outputCursor]=shaped*sinf(carrier*2 * .pi)
        }
        // The last high-rate phase is three sub-samples after the host grid.
        // Decimate at phase zero to keep wet and dry at exactly 24 samples.
        var result=SIMD2<Float>.zero
        for i in 0..<97 { result += output[(outputCursor-3-i)&127]*taps[i] }
        return result
    }
}

final class FXProcessor {
    let kind: EffectKind
    let sr: Float
    private let ringOversampler: FXRingOversampler?
    private let delay: FXStereoLine
    private let pitch: FXStereoLine
    private let predelay: FXStereoLine
    private var tanks: [FXStereoLine] = []
    private var tankTimes=Array(repeating:Float(0),count:8)
    private var tankGains=Array(repeating:Float(0),count:8)
    private var tankFilters=Array(repeating:SIMD2<Float>.zero,count:8)
    private var target=SIMD8<Float>(repeating:0)
    private var smooth=SIMD8<Float>(repeating:0)
    private var phase: Float=0, carrier: Float=0, pitchPhase: Float=0, reversePhase: Float=0
    private var filtered=SIMD2<Float>.zero
    private var previous=SIMD2<Float>.zero
    private var damping: Float=0.2, wetGain: Float=0, envelope: Float=0
    private var settings: FXSettings
    private var initialized=false
    private var previousReverseRead=SIMD2<Float>.zero
    private var previousReversePhase=SIMD2<Float>(repeating:-1)
    private var lastEchoDelay: Float?
    private var delaySamples: Float=1
    private var loop: [SIMD2<Float>] = []
    private var loopPosition: Float=0, loopLength=0, lastLoopSerial: UInt32=0
    private(set) var loopState=0
    var loopSeconds: Float { Float(loopLength)/sr }

    init(kind: EffectKind,sampleRate: Float) {
        self.kind=kind; sr=sampleRate; settings=FXSettings(kind)
        ringOversampler=kind == .ring ? FXRingOversampler():nil
        if kind == .time || kind == .pedal || kind == .studio { _=FXDelayKernels.coefficients }
        delay=FXStereoLine(capacity:Int(sampleRate*(kind == .pedal ? 4.2:2.2))+8)
        pitch=FXStereoLine(capacity:Int(sampleRate*0.12)+8)
        predelay=FXStereoLine(capacity:Int(sampleRate*0.21)+8)
        if kind == .sky { tanks=(0..<8).map { _ in FXStereoLine(capacity:Int(sampleRate*0.25)+8) } }
        if kind == .pedal { loop=Array(repeating:.zero,count:Int(sampleRate*12)) }
    }
    func reset() {
        delay.reset();pitch.reset();predelay.reset();ringOversampler?.reset()
        for tank in tanks { tank.reset() }
        for i in tankFilters.indices { tankFilters[i] = .zero }
        phase=0;carrier=0;pitchPhase=0;reversePhase=0
        filtered = .zero;previous = .zero;previousReverseRead = .zero
        previousReversePhase=SIMD2(repeating:-1);lastEchoDelay=nil
        wetGain=0;envelope=0;smooth=target
        delaySamples=25*powf(80,target[0])*0.001*sr
        loopPosition=0;loopLength=0;loopState=0;lastLoopSerial=settings.loopSerial
    }
    func configure(_ next: FXSettings) {
        if kind == .pedal, next.loopSerial != lastLoopSerial {
            lastLoopSerial=next.loopSerial
            switch next.loopAction {
            case 1:
                if loopState == 1 { loopState=loopLength > 0 ? 2:0; loopPosition=0 }
                else if loopState == 2 { loopState=3 }
                else if loopState == 3 { loopState=2 }
                else { loopState=1; loopPosition=0; loopLength=0 }
            case 2: loopState=loopState == 2 || loopState == 3 ? 4:(loopLength > 0 ? 2:0)
            case 3: loopState=0; loopLength=0; loopPosition=0
            default: break
            }
        }
        guard !initialized || next != settings else { return }
        settings=next
        for index in next.values.indices { target[index]=next.values[index] }
        if !initialized { smooth=target; initialized=true; delaySamples=25*powf(80,target[0])*0.001*sr }
        damping=1-expf(-2 * .pi * (500+powf(target[2],2)*14000)/sr)
        if kind == .sky {
            let seconds=kind.controls[0].actual(target[0])
            let times=SIMD8<Float>(0.0297,0.0371,0.0411,0.0437,0.0531,0.0617,0.0719,0.0797)
            let scale: Float=next.mode == 1 ? 0.72:(next.mode >= 2 ? 1.8:1.2)
            for i in 0..<8 {
                tankTimes[i]=times[i]*scale*sr
                tankGains[i]=powf(0.001,times[i]*scale/seconds)
            }
        }
    }
    func process(_ dry: SIMD2<Float>) -> SIMD2<Float> {
        // Slew continuous parameters and bypass, including delay-time changes.
        smooth += (target-smooth)*min(1,1/(sr*0.02))
        wetGain += ((settings.enabled ? 1:0)-wetGain)*min(1,1/(sr*0.008))
        if wetGain < 0.00001 && !settings.enabled { return dry }
        let wet: SIMD2<Float>
        switch kind {
        case .dimension: wet=modulation(dry,studio:false)
        case .sky: wet=reverb(dry)
        case .time: wet=echo(dry,mode:settings.mode)
        case .pedal: wet=settings.mode == 3 ? looper(dry):echo(dry,mode:settings.mode == 2 ? 4:settings.mode)
        case .ring: wet=ring(dry)
        case .studio: wet=settings.mode == 2 ? echo(dry,mode:3,studio:true):modulation(dry,studio:true)
        default: return dry
        }
        let mix=smooth[4]*wetGain
        if kind == .ring, let oversampler=ringOversampler {
            // Align the dry/wet paths while engaged, then crossfade back to the
            // un-delayed signal on bypass. Fully bypassed samples remain exact.
            let aligned=oversampler.alignedDry
            return dry*(1-wetGain)+(aligned*(1-smooth[4])+wet*smooth[4])*wetGain
        }
        return dry*(1-mix)+wet*mix
    }
    private func modulation(_ input: SIMD2<Float>,studio: Bool) -> SIMD2<Float> {
        let rate=studio ? 0.05*powf(100,smooth[0]):0.03*powf(5/0.03,smooth[0])
        phase += rate/sr; phase -= floorf(phase)
        let a=sinf(2 * .pi * phase), b=sinf(2 * .pi * phase + .pi*0.5)
        let dimension=studio ? settings.mode == 0:settings.mode == 0
        let base: Float=dimension ? 8+smooth[2]*18:(studio ? 0.7+smooth[2]*9:0.3+smooth[2]*11.7)
        let width: Float=dimension ? 7: min(base*0.9,5)
        let l=delay.read((base+width*smooth[1]*a)*0.001*sr)
        let r=delay.read((base+width*smooth[1]*b)*0.001*sr)
        var result=SIMD2(l.x,r.y)
        if dimension {
            let second=delay.read((base-width*smooth[1]*b)*0.001*sr)
            result=(result+SIMD2(second.y,-second.x))*0.5
        }
        if studio { filtered += (result-filtered)*damping; result=filtered }
        let feedback: Float=dimension ? smooth[3]*0.2:(studio ? smooth[3]*0.92:smooth[3]*0.92*(settings.mode == 2 ? -1:1))
        let sample=input+result*feedback
        delay.write(SIMD2(tanhf(sample.x),tanhf(sample.y)))
        return result
    }
    private func echo(_ input: SIMD2<Float>,mode: Int,studio: Bool=false) -> SIMD2<Float> {
        let normalized=smooth[0]
        let milliseconds: Float=25*powf(80,normalized)
        let desired=milliseconds*0.001*sr
        delaySamples += (desired-delaySamples)*min(1,1/(sr*0.05))
        let modulation=studio ? smooth[1]:smooth[3]
        phase += (0.15+modulation*1.4)/sr; phase -= floorf(phase)
        let wow=sinf(phase*2 * .pi)*modulation*(mode == 1 ? 0.004:0.0008)*sr
        let readDelay=delaySamples+wow
        let readSpeed=1-(readDelay-(lastEchoDelay ?? readDelay))
        lastEchoDelay=readDelay
        var wet=SIMD2<Float>.zero
        if mode == 4 {
            // Two overlapping reverse grains avoid a discontinuity at wrap.
            reversePhase += 1/max(32,delaySamples); reversePhase -= floorf(reversePhase)
            let q=reversePhase < 0.5 ? reversePhase+0.5:reversePhase-0.5
            let w=0.5-0.5*cosf(reversePhase*2 * .pi)
            let positions=SIMD2(reversePhase,q)
            let rawDistances=1+positions*delaySamples*2
            let distances=SIMD2(max(17,rawDistances.x),max(17,rawDistances.y))
            var speeds=SIMD2<Float>(repeating:-1)
            for head in 0..<2 {
                // Grain wrap is an intentional seek at zero window gain, not
                // a read-speed spike. Time changes within each grain are real.
                if previousReversePhase[head]>=0 && abs(positions[head]-previousReversePhase[head])<0.5 {
                    speeds[head]=1-(distances[head]-previousReverseRead[head])
                }
            }
            previousReverseRead=distances; previousReversePhase=positions
            wet=delay.readBandlimited(distances.x,speed:speeds.x)*w+delay.readBandlimited(distances.y,speed:speeds.y)*(1-w)
        } else {
            wet=delay.readBandlimited(readDelay,speed:readSpeed)
        }
        let coefficient=mode == 2 ? min(damping,0.12):damping
        filtered += (wet-filtered)*coefficient
        wet=filtered
        let feedback=studio ? smooth[3]*0.92:smooth[1]*0.94
        let returned=mode == 3 ? SIMD2(wet.y,wet.x):wet
        var feed=input+returned*feedback
        if mode == 1 || mode == 2 { feed=SIMD2(tanhf(feed.x*1.2),tanhf(feed.y*1.2))/1.2 }
        // Alternate the injected channels for a true stereo ping-pong echo.
        if mode == 3 { feed=SIMD2((input.x+input.y)*0.5+returned.x*feedback,returned.y*feedback) }
        delay.write(feed)
        if studio {
            let level=max(abs(input.x),abs(input.y))
            envelope += (level-envelope)*min(1,1/(sr*(level > envelope ? 0.005:0.25)))
            wet /= 1+envelope*12
        }
        return wet
    }
    private func reverb(_ input: SIMD2<Float>) -> SIMD2<Float> {
        let pre=predelay.read(max(1,smooth[1]*0.2*sr)); predelay.write(input)
        phase += 0.17/sr; phase -= floorf(phase)
        var reads=SIMD8<Float>(repeating:0), sum: Float=0
        for i in 0..<8 {
            let modulation=sinf(phase*2 * .pi+Float(i))*smooth[3]*sr*0.0007
            let value=tanks[i].read(tankTimes[i]+modulation)
            tankFilters[i] += (value-tankFilters[i])*damping
            reads[i]=tankFilters[i].x
            sum += reads[i]
        }
        // Orthogonal Householder FDN, eight unequal delays and damping.
        let shimmer: Float
        if settings.mode == 3 {
            pitch.write(previous)
            pitchPhase += 1/(sr*0.06); pitchPhase -= floorf(pitchPhase)
            let q=pitchPhase < 0.5 ? pitchPhase+0.5:pitchPhase-0.5
            let w=0.5-0.5*cosf(pitchPhase*2 * .pi)
            let shifted=pitch.read(1+(1-pitchPhase)*sr*0.06)*w+pitch.read(1+(1-q)*sr*0.06)*(1-w)
            shimmer=(shifted.x+shifted.y)*0.08
        } else { shimmer=0 }
        for i in 0..<8 {
            let reflected=reads[i]-sum*0.25
            let injection=(i%2 == 0 ? pre.x:pre.y)*0.5*(i%4 < 2 ? 1:-1)+shimmer
            let sample=tanhf(injection+reflected*tankGains[i])
            tanks[i].write(SIMD2(repeating:sample))
        }
        var wet=SIMD2((reads[0]+reads[2]-reads[4]+reads[6])*0.5,(reads[1]-reads[3]+reads[5]+reads[7])*0.5)
        if settings.mode == 2 { wet=(wet+previous)*0.5 }
        previous=wet
        return wet
    }
    private func ring(_ input: SIMD2<Float>) -> SIMD2<Float> {
        phase += 0.1*powf(250,smooth[1])/sr; phase -= floorf(phase)
        let lfo=settings.mode%2 == 0 ? sinf(phase*2 * .pi):1-4*abs(phase-0.5)
        let low=settings.mode < 2
        let frequency=(low ? 0.6*powf(80/0.6,smooth[0]):30*powf(4000/30,smooth[0]))*powf(2,lfo*smooth[2]*2)
        return ringOversampler!.process(input,carrier:&carrier,step:min(sr*0.4,frequency)/sr,drive:1+smooth[3]*7)
    }
    private func looper(_ input: SIMD2<Float>) -> SIMD2<Float> {
        if loopState == 1 {
            loop[loopLength]=input; loopLength += 1
            if loopLength == loop.count { loopState=2; loopPosition=0 }
            return input
        }
        guard loopLength > 0, loopState == 2 || loopState == 3 else { return .zero }
        let index=min(loopLength-1,max(0,Int(loopPosition)))
        let next=(index+1)%loopLength, fraction=loopPosition-Float(index)
        let sample=loop[index]*(1-fraction)+loop[next]*fraction
        if loopState == 3 { loop[index]=loop[index]*0.98+input*0.6 }
        let speed: Float=settings.halfSpeed ? 0.5:1
        loopPosition += settings.reverse ? -speed:speed
        if loopPosition < 0 { loopPosition += Float(loopLength) }
        if loopPosition >= Float(loopLength) { loopPosition -= Float(loopLength) }
        return sample
    }
}

/// Audio thread owns processor state. UI supplies only validated small snapshots.
final class EffectsRackDSP {
    private var configuration=try! FXDocument.initial.configuration()
    private var processors: [FXProcessor?]
    private var values=Array(repeating:SIMD2<Float>.zero,count:9)
    private var previous=SIMD2<Float>.zero
    private var transition: Float=1
    private let sampleRate: Float
    init(sampleRate: Float) {
        self.sampleRate=sampleRate
        processors=EffectKind.allCases.map { (1...6).contains($0.rawValue) ? FXProcessor(kind:$0,sampleRate:sampleRate):nil }
    }
    func reset() {
        for processor in processors { processor?.reset() }
        for i in values.indices { values[i] = .zero }
        previous = .zero;transition=1
    }
    func prepare(_ next: FXRenderConfiguration) {
        if configuration.steps != next.steps { transition=0 }
        configuration=next
        for i in 1...6 { processors[i]?.configure(next.settings[i]) }
    }
    func process(_ input: SIMD2<Float>) -> SIMD2<Float> {
        values[0]=input
        for step in configuration.steps {
            let a=step.a >= 0 ? values[step.a]:.zero
            if step.id == 7 {
                let b=step.b >= 0 ? values[step.b]:.zero
                let settings=configuration.settings[7]
                values[7]=a*settings.values[0]+b*settings.values[1]
            } else if step.id == 8 { values[8]=a }
            else { values[step.id]=processors[step.id]!.process(a) }
        }
        let output=values[8]
        transition=min(1,transition+1/(sampleRate*0.01))
        let result=previous*(1-transition)+output*transition
        if transition == 1 { previous=output }
        return SIMD2(result.x.isFinite ? min(1,max(-1,result.x)):0,result.y.isFinite ? min(1,max(-1,result.y)):0)
    }
    var loopState: Int { processors[4]?.loopState ?? 0 }
    var loopSeconds: Float { processors[4]?.loopSeconds ?? 0 }
}
