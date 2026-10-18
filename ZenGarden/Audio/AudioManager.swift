import AVFoundation

/// Names of every one-shot sound. A file named `<rawValue>.wav|.caf|.m4a|.aif` in the app
/// bundle replaces the procedural placeholder automatically (see SOUNDS.md).
enum SoundName: String, CaseIterable {
    case stoneSmall = "stone_place_small"
    case stoneLarge = "stone_place_large"
    case stoneLift = "stone_lift"
    case toolSelect = "tool_select"
    case uiTap = "ui_tap"
    case patternComplete = "pattern_complete"
    case introSwish = "intro_swish"
    case gardenSwap = "garden_swap"
}

/// Continuous sand textures. A loop file named `<loopName>` replaces the procedural voice.
enum ScrapeProfile {
    case fine, wide, wave, smoother, sweep, rings

    var loopName: String {
        switch self {
        case .fine: return "rake_fine_loop"
        case .wide: return "rake_wide_loop"
        case .wave: return "rake_wave_loop"
        case .smoother, .sweep: return "smoother_loop"
        case .rings: return "rake_wave_loop"
        }
    }

    /// Maps intensity (0...1, mostly finger speed) to the timbre of the sand.
    func params(intensity s: Float, onset: Float, pan: Float) -> ScrapeParams {
        let x = max(0, min(1, s))
        let lift = 1 + onset * 0.35          // a slightly crunchier bite when the tool first touches
        switch self {
        case .fine:
            return ScrapeParams(gain: 0.62 * pow(x, 0.7) * lift, cutoff: 2500 + 900 * x, q: 0.85,
                                grainRate: 300 + 2600 * x, grainGain: 0.85, hiss: 0.32, rumble: 0.02, pan: pan)
        case .wide:
            return ScrapeParams(gain: 0.70 * pow(x, 0.7) * lift, cutoff: 1150 + 500 * x, q: 0.75,
                                grainRate: 220 + 1800 * x, grainGain: 0.8, hiss: 0.45, rumble: 0.35, pan: pan)
        case .wave:
            return ScrapeParams(gain: 0.64 * pow(x, 0.7) * lift, cutoff: 1800 + 650 * x, q: 0.8,
                                grainRate: 260 + 2000 * x, grainGain: 0.8, hiss: 0.4, rumble: 0.15, pan: pan)
        case .smoother:
            return ScrapeParams(gain: 0.62 * pow(x, 0.75), cutoff: 720 + 380 * x, q: 0.55,
                                grainRate: 40 + 320 * x, grainGain: 0.35, hiss: 0.85, rumble: 0.28, pan: pan)
        case .sweep:
            return ScrapeParams(gain: 0.55 * x, cutoff: 650 + 350 * x, q: 0.5,
                                grainRate: 60 + 500 * x, grainGain: 0.35, hiss: 0.9, rumble: 0.3, pan: pan)
        case .rings:
            return ScrapeParams(gain: 0.5 * x, cutoff: 1600 + 500 * x, q: 0.8,
                                grainRate: 200 + 1300 * x, grainGain: 0.75, hiss: 0.38, rumble: 0.1, pan: pan)
        }
    }
}

/// Audio engine for the whole app.
/// Session category is `.ambient` (studio rule): plays only when the iPhone is not on silent,
/// mixes with other audio and never shows up in the Dynamic Island.
final class AudioManager {
    static let shared = AudioManager()

    private let engine = AVAudioEngine()
    private var format: AVAudioFormat!
    private var voices: [ScrapeVoice] = []
    private var loopVoices: [String: LoopVoice] = [:]
    private var activeLoop: [Int: String] = [:]
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [SoundName: [AVAudioPCMBuffer]] = [:]
    private var started = false
    private var lastPlayed: [SoundName: CFTimeInterval] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [])
        try? session.setActive(true)

        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = hwRate > 0 ? hwRate : 48000
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)

        for i in 0..<2 {
            let v = ScrapeVoice(format: format, seed: UInt32(0x9E37 &+ i &* 7919))
            engine.attach(v.node)
            engine.connect(v.node, to: engine.mainMixerNode, format: format)
            voices.append(v)
        }
        for _ in 0..<6 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        buildBuffers()
        buildLoopOverrides()
        applySettings()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(configurationChanged), name: .AVAudioEngineConfigurationChange, object: engine)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: session)

        engine.prepare()
        resume()
    }

    func suspend() {
        voices.forEach { $0.silence() }
        engine.pause()
    }

    func resume() {
        guard started else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        for p in players where !p.isPlaying { p.play() }
    }

    func applySettings() {
        let s = SettingsManager.shared
        engine.mainMixerNode.outputVolume = s.soundOn ? Float(s.volume) : 0
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended { DispatchQueue.main.async { self.resume() } }
    }

    @objc private func configurationChanged() {
        DispatchQueue.main.async { self.resume() }
    }

    @objc private func mediaReset() {
        DispatchQueue.main.async { self.resume() }
    }

    // MARK: - Continuous sand

    /// Voice 0 follows the finger; voice 1 is used by animations (sweep, ripples, intro).
    func setScrape(voice: Int, profile: ScrapeProfile, intensity: Float, pan: Float = 0, onset: Float = 0) {
        guard voice < voices.count else { return }
        if let loop = loopVoices[profile.loopName] {
            if let prev = activeLoop[voice], prev != profile.loopName { loopVoices[prev]?.set(level: 0, rate: 1) }
            activeLoop[voice] = profile.loopName
            loop.set(level: intensity, rate: 0.88 + 0.24 * intensity)
            voices[voice].silence()
            return
        }
        voices[voice].set(profile.params(intensity: intensity, onset: onset, pan: pan))
    }

    func stopScrape(voice: Int) {
        guard voice < voices.count else { return }
        voices[voice].silence()
        if let prev = activeLoop[voice] { loopVoices[prev]?.set(level: 0, rate: 1); activeLoop[voice] = nil }
    }

    // MARK: - One-shots

    func play(_ name: SoundName, volume: Float = 1, pan: Float = 0, minInterval: CFTimeInterval = 0.03) {
        guard started, let variants = buffers[name], let buffer = variants.randomElement() else { return }
        let now = CACurrentMediaTime()
        if let last = lastPlayed[name], now - last < minInterval { return }
        lastPlayed[name] = now
        if !engine.isRunning { resume() }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        p.volume = volume
        p.pan = max(-1, min(1, pan))
        p.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }
    }

    // MARK: - Buffers

    private func buildBuffers() {
        let fs = Float(format.sampleRate)
        for name in SoundName.allCases {
            if let file = Self.bundledFile(name.rawValue), let b = loadFile(file) {
                buffers[name] = [b]
                continue
            }
            var variants: [[Float]] = []
            for v in 0..<3 {
                let seed = UInt32(1000 + v * 77 + name.rawValue.count * 13)
                switch name {
                case .stoneSmall: variants.append(SoundSynth.stone(fs: fs, size: 0.2 + Float(v) * 0.08, seed: seed))
                case .stoneLarge: variants.append(SoundSynth.stone(fs: fs, size: 0.75 + Float(v) * 0.1, seed: seed))
                case .stoneLift: variants.append(SoundSynth.lift(fs: fs, seed: seed))
                case .toolSelect: variants.append(SoundSynth.woodTok(fs: fs, pitch: 1.0, peak: 0.30, seed: seed))
                case .uiTap: variants.append(SoundSynth.woodTok(fs: fs, pitch: 1.25, peak: 0.16, seed: seed))
                case .patternComplete: if v == 0 { variants.append(SoundSynth.chime(fs: fs)) }
                case .introSwish: variants.append(SoundSynth.swish(fs: fs, seconds: 0.75, from: 600, to: 1500, peak: 0.22, seed: seed))
                case .gardenSwap: variants.append(SoundSynth.swish(fs: fs, seconds: 1.0, from: 500, to: 1200, peak: 0.2, seed: seed))
                }
            }
            buffers[name] = variants.compactMap { makeBuffer($0) }
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<Int(format.channelCount) {
            let dst = b.floatChannelData![ch]
            samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        }
        return b
    }

    static func bundledFile(_ name: String) -> URL? {
        for ext in ["wav", "caf", "m4a", "aif", "aiff", "mp3"] {
            if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        }
        return nil
    }

    /// Loads a file and converts it to the engine's stereo format.
    private func loadFile(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return error == nil ? dst : nil
    }

    private func buildLoopOverrides() {
        let names = Set([ScrapeProfile.fine, .wide, .wave, .smoother].map(\.loopName))
        for name in names {
            guard let url = Self.bundledFile(name), let buffer = loadFile(url) else { continue }
            let loop = LoopVoice(buffer: buffer, engine: engine, format: format)
            loopVoices[name] = loop
        }
    }
}

/// A looping recording whose level and playback rate follow the finger.
final class LoopVoice {
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()

    init(buffer: AVAudioPCMBuffer, engine: AVAudioEngine, format: AVAudioFormat) {
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        player.volume = 0
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    func set(level: Float, rate: Float) {
        if !player.isPlaying, player.engine?.isRunning == true { player.play() }
        player.volume = max(0, min(1, level))
        varispeed.rate = max(0.5, min(2, rate))
    }
}
