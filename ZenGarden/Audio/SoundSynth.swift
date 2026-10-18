import AVFoundation

/// Procedural one-shot sounds, rendered once at launch.
///
/// These are placeholders for real recordings: drop a file with the same name
/// (see `SoundName` and SOUNDS.md) into Resources/Sounds and it is used instead.
enum SoundSynth {
    /// Small state-variable filter for offline rendering.
    struct SVF {
        var ic1: Float = 0, ic2: Float = 0
        mutating func bandpass(_ x: Float, fc: Float, q: Float, fs: Float) -> Float {
            let g = tan(.pi * min(fc, fs * 0.45) / fs), k = 1 / q
            let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
            let v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
            return v1 * k
        }
    }

    struct Rng {
        var s: UInt32
        mutating func next() -> Float {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            return Float(Int32(bitPattern: s)) / 2147483648.0
        }
    }

    static func normalize(_ x: inout [Float], peak: Float) {
        let m = x.reduce(0) { max($0, abs($1)) }
        guard m > 0 else { return }
        let k = peak / m
        for i in x.indices { x[i] *= k }
        // 4 ms fade-out guard against clicks at the very end.
        let fade = min(x.count, 200)
        for i in 0..<fade { x[x.count - 1 - i] *= Float(i) / Float(fade) }
    }

    /// A stone settling into sand: soft low thump + crunch of grains + a short sandy settle.
    static func stone(fs: Float, size: Float, seed: UInt32) -> [Float] {
        var rng = Rng(s: seed | 1)
        let detune = 1 + rng.next() * 0.06
        let f0 = (150 - 55 * size) * detune
        let n = Int(fs * (0.5 + 0.25 * size))
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var crunch = SVF(), settle = SVF()
        for i in 0..<n {
            let t = Float(i) / fs
            let attack = 1 - exp(-t / 0.0025)
            let env = attack * exp(-t / (0.07 + 0.05 * size))
            let f = f0 * (1 + 0.5 * exp(-t / 0.012))
            phase += 2 * .pi * f / fs
            let body = sin(phase) * env * 0.6
            let over = sin(phase * 2.7 + 0.3) * attack * exp(-t / 0.02) * 0.12
            let c = crunch.bandpass(rng.next(), fc: 950 + 250 * size, q: 1.1, fs: fs) * (1 - exp(-t / 0.001)) * exp(-t / 0.035) * 0.55
            let sv = settle.bandpass(rng.next(), fc: 620, q: 0.7, fs: fs) * smoothstepf(0, 0.03, t) * exp(-t / 0.16) * 0.14
            out[i] = body + over + c + sv
        }
        normalize(&out, peak: 0.55 + 0.2 * size)
        return out
    }

    /// Lifting a stone out of the sand: a soft "shff".
    static func lift(fs: Float, seed: UInt32) -> [Float] {
        var rng = Rng(s: seed | 1)
        let n = Int(fs * 0.32)
        var out = [Float](repeating: 0, count: n)
        var f = SVF()
        let centre: Float = 1250 + rng.next() * 150
        for i in 0..<n {
            let t = Float(i) / fs
            let env = smoothstepf(0, 0.03, t) * exp(-max(t - 0.03, 0) / 0.09)
            out[i] = f.bandpass(rng.next(), fc: centre, q: 0.9, fs: fs) * env
        }
        normalize(&out, peak: 0.2)
        return out
    }

    /// Wooden "tok": modal synthesis of a small block of wood, warm and short.
    static func woodTok(fs: Float, pitch: Float, peak: Float, seed: UInt32) -> [Float] {
        var rng = Rng(s: seed | 1)
        let modes: [(Float, Float, Float)] = [(480, 0.045, 1.0), (1250, 0.018, 0.3), (2150, 0.008, 0.09)]
        let p = pitch * (1 + rng.next() * 0.03)
        let n = Int(fs * 0.2)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / fs
            let att = 1 - exp(-t / 0.0015)
            var s: Float = 0
            for (f, d, a) in modes { s += sin(2 * .pi * f * p * t) * exp(-t / d) * a }
            out[i] = s * att
        }
        normalize(&out, peak: peak)
        return out
    }

    /// Reward chime: a soft wooden marimba arpeggio in a low-mid register (D major pentatonic).
    static func chime(fs: Float) -> [Float] {
        let notes: [(Float, Float)] = [(293.66, 0.0), (369.99, 0.13), (440.0, 0.26), (587.33, 0.42)]
        let n = Int(fs * 2.4)
        var out = [Float](repeating: 0, count: n)
        for (f, start) in notes {
            let s0 = Int(start * fs)
            for i in s0..<n {
                let t = Float(i - s0) / fs
                let att = 1 - exp(-t / 0.004)
                let v = sin(2 * .pi * f * t) * exp(-t / 0.9)
                    + sin(2 * .pi * f * 3.93 * t) * exp(-t / 0.12) * 0.10
                    + sin(2 * .pi * f * 9.2 * t) * exp(-t / 0.03) * 0.025
                out[i] += v * att * 0.3
            }
        }
        normalize(&out, peak: 0.34)
        return out
    }

    /// Breath of sand used in the BluBer intro and when the gardens cross-fade.
    static func swish(fs: Float, seconds: Float, from: Float, to: Float, peak: Float, seed: UInt32) -> [Float] {
        var rng = Rng(s: seed | 1)
        let n = Int(fs * seconds)
        var out = [Float](repeating: 0, count: n)
        var a = SVF(), b = SVF()
        for i in 0..<n {
            let t = Float(i) / Float(n)
            let fc = from + (to - from) * sin(t * .pi * 0.5)
            let env = pow(sin(t * .pi), 1.6)
            let x = rng.next()
            out[i] = (a.bandpass(x, fc: fc, q: 0.8, fs: fs) * 0.8 + b.bandpass(x, fc: fc * 0.5, q: 0.6, fs: fs) * 0.4) * env
        }
        normalize(&out, peak: peak)
        return out
    }
}
