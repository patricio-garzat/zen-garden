import AVFoundation

/// Target parameters for the continuous sand voice. Written on the main thread,
/// read (and smoothed per sample) on the audio thread.
struct ScrapeParams {
    var gain: Float = 0          // overall level
    var cutoff: Float = 2000     // band-pass centre of the hiss (Hz)
    var q: Float = 0.8
    var grainRate: Float = 0     // micro-impacts per second (the "granular" crackle of sand)
    var grainGain: Float = 0
    var hiss: Float = 0.5        // continuous friction noise
    var rumble: Float = 0        // low body for deep tools
    var pan: Float = 0           // -1...1
}

/// Real-time procedural sand: band-passed friction noise + randomly triggered grain clicks
/// + a low rumble, all smoothed so changes in finger speed never click or step.
final class ScrapeDSP {
    private let fs: Float
    private var cur = ScrapeParams()
    private var seed: UInt32
    private var ic1: Float = 0, ic2: Float = 0         // hiss SVF state
    private var gc1: Float = 0, gc2: Float = 0         // grain SVF state
    private var lp1: Float = 0, lp2: Float = 0         // rumble
    private var out: Float = 0
    private var grainEnv: Float = 0
    private var drift: Float = 0
    private let grainDecay: Float
    private let outK: Float
    private let rumbleK: Float

    init(sampleRate: Float, seed: UInt32) {
        fs = sampleRate
        self.seed = seed | 1
        grainDecay = exp(-1 / (0.0018 * sampleRate))
        outK = 1 - exp(-2 * .pi * 6500 / sampleRate)
        rumbleK = 1 - exp(-2 * .pi * 260 / sampleRate)
    }

    @inline(__always) private func rnd() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) * (1.0 / 2147483648.0)
    }

    @inline(__always) private func rnd01() -> Float { rnd() * 0.5 + 0.5 }

    func render(target: ScrapeParams, frames: Int, abl: UnsafeMutablePointer<AudioBufferList>, isSilence: UnsafeMutablePointer<ObjCBool>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let lData = buffers[0].mData else { return }
        let left = lData.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left

        if target.gain < 0.0001 && cur.gain < 0.0002 && abs(out) < 0.00001 {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            cur.gain = 0
            isSilence.pointee = true
            return
        }

        var i = 0
        while i < frames {
            let block = min(32, frames - i)
            // ~25 ms parameter smoothing.
            let k = 1 - exp(-Float(block) / (0.025 * fs))
            cur.gain += (target.gain - cur.gain) * k
            cur.cutoff += (target.cutoff - cur.cutoff) * k
            cur.q += (target.q - cur.q) * k
            cur.grainRate += (target.grainRate - cur.grainRate) * k
            cur.grainGain += (target.grainGain - cur.grainGain) * k
            cur.hiss += (target.hiss - cur.hiss) * k
            cur.rumble += (target.rumble - cur.rumble) * k
            cur.pan += (target.pan - cur.pan) * k
            // Slow random walk of the timbre so long strokes never sound looped.
            drift = clampf(drift + rnd() * 0.02, -1, 1) * 0.995

            let fc = min(cur.cutoff * (1 + drift * 0.08), fs * 0.42)
            let g = tan(.pi * fc / fs)
            let kq = 1 / max(cur.q, 0.3)
            let a1 = 1 / (1 + g * (g + kq)), a2 = g * a1, a3 = g * a2
            let gf = min(fc * 1.3, fs * 0.42)
            let gg = tan(.pi * gf / fs)
            let gk: Float = 1 / 1.1
            let b1 = 1 / (1 + gg * (gg + gk)), b2 = gg * b1, b3 = gg * b2
            let panA = (cur.pan + 1) * (.pi / 4)
            let pl = cos(panA) * 1.41, pr = sin(panA) * 1.41
            let trigger = cur.grainRate / fs

            for _ in 0..<block {
                let n1 = rnd(), n2 = rnd()
                // Hiss (TPT state-variable band-pass, unity gain at the centre).
                let v3 = n1 - ic2
                let v1 = a1 * ic1 + a2 * v3
                let v2 = ic2 + a2 * ic1 + a3 * v3
                ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
                let hiss = v1 * kq

                // Grains: short decaying bursts at random times.
                if rnd01() < trigger { grainEnv = 0.35 + 0.65 * rnd01() }
                grainEnv *= grainDecay
                let gx = n2 * grainEnv
                let w3 = gx - gc2
                let w1 = b1 * gc1 + b2 * w3
                let w2 = gc2 + b2 * gc1 + b3 * w3
                gc1 = 2 * w1 - gc1; gc2 = 2 * w2 - gc2
                let grain = w1 * gk

                lp1 += (n1 - lp1) * rumbleK
                lp2 += (lp1 - lp2) * rumbleK

                var s = (hiss * cur.hiss + grain * cur.grainGain * 1.6 + lp2 * cur.rumble * 3.0) * cur.gain
                s = s / (1 + abs(s))                // gentle safety saturation
                out += (s - out) * outK              // warm: nothing sharp above ~6.5 kHz
                left[i] = out * pl
                right[i] = out * pr
                i += 1
            }
        }
    }
}

/// An AVAudioSourceNode running a ScrapeDSP.
final class ScrapeVoice {
    let node: AVAudioSourceNode
    private let target: UnsafeMutablePointer<ScrapeParams>

    init(format: AVAudioFormat, seed: UInt32) {
        let target = UnsafeMutablePointer<ScrapeParams>.allocate(capacity: 1)
        target.initialize(to: ScrapeParams())
        self.target = target
        let dsp = ScrapeDSP(sampleRate: Float(format.sampleRate), seed: seed)
        node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl -> OSStatus in
            dsp.render(target: target.pointee, frames: Int(frameCount), abl: abl, isSilence: isSilence)
            return noErr
        }
    }

    deinit { target.deallocate() }

    func set(_ p: ScrapeParams) { target.pointee = p }
    func silence() { target.pointee.gain = 0 }
}
