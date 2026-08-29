// Cuelume.swift — native Swift port of cuelume 0.2.2 (recipes + engine).
//
// Drop this single file into your SwiftUI app. No assets, no dependencies.
// Renders each cue to a PCM buffer once, caches it, and replays via a pool of
// AVAudioPlayerNodes (the pool allows overlapping cues, like the web version).
//
// Usage:
//   Button("Save") { Cuelume.shared.play(.success) }
//   Cuelume.shared.volume = 0.5
//   Cuelume.shared.isEnabled = true
//   Cuelume.shared.warmUp()   // optional: pre-render to avoid first-play hitch

import AVFoundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

// MARK: - Public API

public enum Sound: String, CaseIterable, Sendable {
    case chime, sparkle, droplet, bloom, whisper, tick, press, release, toggle
    case success, error, page, loading, ready, pulse, scan, arrival
}

public final class Cuelume {
    public static let shared = Cuelume()

    public var isEnabled = true
    public var volume: Float = 0.7          // global multiplier, like setVolume()

    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var next = 0
    private let sampleRate = 44_100.0
    private let format: AVAudioFormat
    private var cache: [Sound: AVAudioPCMBuffer] = [:]

    // engine.isRunning is NOT proof an IO cycle has actually happened — it's
    // the engine's own software state, which iOS can silently leave stale
    // ("true") across a background/foreground cycle even though the real
    // hardware IO was torn down while suspended (.ambient doesn't keep audio
    // alive in background). Relying on isRunning alone let a notification
    // tap resume straight into node.play() on a graph with zero real IO
    // cycles → the crash this file guards against. isWarm is our own,
    // deterministically-tracked ground truth instead: false whenever we
    // (re)start the engine, flipped true only by installTap confirming a
    // real render callback actually happened. main-actor only — every read/
    // write here is already on the main thread (play() callers, the tap's
    // own dispatch-to-main, and the lifecycle notifications below).
    private var isWarm = false

    private init() {
        // ponytail: stay silent under XCTest so unit runs don't play cues.
        if NSClassFromString("XCTestCase") != nil { isEnabled = false }
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate, channels: 1, interleaved: false)!
        for _ in 0..<12 {                     // voice pool → overlapping cues
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            voices.append(node)
        }
        configureSession()
        startAndConfirmWarm()
        observeLifecycle()
    }

    private func configureSession() {
        #if os(iOS) || os(tvOS)
        let s = AVAudioSession.sharedInstance()
        // .ambient => respects the mute switch and mixes with other audio (polite for UI cues).
        try? s.setCategory(.ambient, options: [.mixWithOthers])
        try? s.setActive(true)
        #endif
    }

    /// Two distinct things can take the engine cold, and neither shows up
    /// in `engine.isRunning` (see the `isWarm` doc above):
    ///  - plain backgrounding (UIApplication lifecycle) — the case fix #2
    ///    covered.
    ///  - something else actively taking the audio session — a phone/
    ///    FaceTime call, Siri, an alarm — which fires an AVAudioSession
    ///    interruption and can happen while Spectra is still foregrounded
    ///    (e.g. tapping a notification while already mid-FaceTime-call).
    ///    Missing this is what let a second crash through: the app never
    ///    saw a background/foreground transition at all, so fix #2's
    ///    isWarm invalidation never ran. iOS/tvOS only — macOS has neither
    ///    concept to guard against.
    private func observeLifecycle() {
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isWarm = false }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.startAndConfirmWarm() }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began: self.isWarm = false
            case .ended: self.startAndConfirmWarm()
            @unknown default: break
            }
        }
        #endif
    }

    /// Non-nil only in tests: `secondaryAudioShouldBeSilencedHint` reflects
    /// real system audio-route state and can't be forced true from a test
    /// process without an actual concurrent call — this override is the
    /// seam that makes shouldStayQuiet()'s branches testable anyway.
    var _test_shouldStayQuietOverride: Bool?

    /// Apple's own signal for "something more important owns audio right
    /// now — a call, Siri, an alarm" (true for the entire duration of a
    /// FaceTime/phone call, not just around the interruption edges). A
    /// UI chime has no business fighting that: activating our own session
    /// mid-call (even `.ambient`/`.mixWithOthers`) can audibly glitch the
    /// call's own route, on top of racing straight back into the exact
    /// IO-cycle crash this file exists to prevent. Skip everything —
    /// don't even attempt engine.start() — while this is true.
    private func shouldStayQuiet() -> Bool {
        if let override = _test_shouldStayQuietOverride { return override }
        #if os(iOS) || os(tvOS)
        return AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        #else
        return false
        #endif
    }

    /// (Re)starts the engine and proves warmth with a one-shot tap instead
    /// of guessing at a delay — the tap callback only fires once CoreAudio
    /// has actually rendered a buffer, which is the one true signal that
    /// AVAudioPlayerNode.play() is now safe to call.
    private func startAndConfirmWarm() {
        guard !shouldStayQuiet() else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)  // idempotent if none installed
        mixer.installTap(onBus: 0, bufferSize: 256, format: mixer.outputFormat(forBus: 0)) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engine.mainMixerNode.removeTap(onBus: 0)
                self.isWarm = true
            }
        }
    }

    /// Plays a cue immediately. Overlap-safe; no-op when disabled.
    ///
    /// Returns whether it actually scheduled a play. Two things skip a
    /// play rather than risk it: `shouldStayQuiet()` (a call/Siri/alarm
    /// owns audio right now — don't fight it, don't even try to warm up),
    /// and a cold `isWarm` (freshly launched, or resuming from background/
    /// an interruption where the engine's IO was torn down invisibly to
    /// `engine.isRunning`). Either miss let AVAudioPlayerNode.play() get
    /// called before the engine had rendered a single real IO cycle —
    /// an uncaught NSException ("player did not see an IO cycle") that
    /// crashes the whole app, reliably hit via a notification tap.
    @discardableResult
    public func play(_ sound: Sound, volume perPlay: Float = 1) -> Bool {
        guard isEnabled, volume * perPlay > 0, !shouldStayQuiet() else { return false }
        guard isWarm else {
            startAndConfirmWarm()
            return false
        }
        let buffer = cache[sound] ?? {
            let b = CuelumeSynth.render(RECIPES[sound]!, sampleRate: sampleRate, format: format)
            cache[sound] = b; return b
        }()
        let node = voices[next]; next = (next + 1) % voices.count
        node.volume = min(1, max(0, volume * perPlay))
        node.scheduleBuffer(buffer, at: nil, options: [])
        if !node.isPlaying { node.play() }
        return true
    }

    /// Optional: pre-render everything up front to avoid a first-play hitch.
    public func warmUp() { for s in Sound.allCases { play(s, volume: 0) } }

    // MARK: - Test-only hooks (internal: visible to @testable import only)

    /// Forces isWarm false directly, without touching the engine — this is
    /// the exact scenario that defeated the first attempt at this fix:
    /// `engine.isRunning` can stay true across a background/foreground
    /// cycle even though the real hardware IO was torn down, so a test (and
    /// the real bug) must be able to go cold independent of engine.isRunning.
    func _test_invalidateWarm() { isWarm = false }
    var _test_isWarm: Bool { isWarm }
    func _test_forceWarm() { isWarm = true }  // bypass startAndConfirmWarm's own shouldStayQuiet() gate for a test
    func _test_triggerWarmUp() { startAndConfirmWarm() }  // direct access to exercise its own shouldStayQuiet() guard
}

// MARK: - Recipe model  (mirrors sounds/recipes.js)

struct Shimmer { let delay, feedback, wet, lowpass: Double }

struct Layer {
    enum Kind { case tone, noise }
    enum Wave { case sine, triangle }
    enum Filter { case lowpass, bandpass }

    var kind: Kind
    var offset = 0.0, attack = 0.0, decay = 0.0, peak = 0.0
    // tone
    var wave: Wave = .sine, frequency = 0.0, detune = 0.0
    var glideTo: Double? = nil, glideTime: Double? = nil
    // noise
    var filter: Filter = .lowpass, filterFrequency = 0.0, filterQ = 1.0

    static func tone(_ w: Wave, _ f: Double, offset: Double = 0, detune: Double = 0,
                     glideTo: Double? = nil, glideTime: Double? = nil,
                     attack: Double, decay: Double, peak: Double) -> Layer {
        Layer(kind: .tone, offset: offset, attack: attack, decay: decay, peak: peak,
              wave: w, frequency: f, detune: detune, glideTo: glideTo, glideTime: glideTime)
    }
    static func noise(_ ft: Filter, _ f: Double, q: Double, offset: Double = 0,
                      attack: Double, decay: Double, peak: Double) -> Layer {
        Layer(kind: .noise, offset: offset, attack: attack, decay: decay, peak: peak,
              filter: ft, filterFrequency: f, filterQ: q)
    }
}

struct Recipe { let masterGain: Double; let layers: [Layer]; var shimmer: Shimmer? = nil }

let RECIPES: [Sound: Recipe] = [
    .chime: Recipe(masterGain: 0.5, layers: [
        .tone(.sine, 1046.5, attack: 0.006, decay: 0.22, peak: 0.09),
        .tone(.sine, 1568, offset: 0.09, attack: 0.006, decay: 0.26, peak: 0.08),
    ], shimmer: Shimmer(delay: 0.12, feedback: 0.25, wet: 0.18, lowpass: 4000)),

    .sparkle: Recipe(masterGain: 0.5, layers: [
        .tone(.sine, 1760, offset: 0, attack: 0.003, decay: 0.09, peak: 0.045),
        .tone(.sine, 2217, offset: 0.045, attack: 0.003, decay: 0.09, peak: 0.04),
        .tone(.sine, 2637, offset: 0.09, attack: 0.003, decay: 0.1, peak: 0.038),
        .tone(.sine, 3520, offset: 0.135, attack: 0.003, decay: 0.12, peak: 0.032),
    ], shimmer: Shimmer(delay: 0.07, feedback: 0.35, wet: 0.22, lowpass: 6000)),

    .droplet: Recipe(masterGain: 0.55, layers: [
        .tone(.sine, 1200, glideTo: 550, glideTime: 0.14, attack: 0.004, decay: 0.2, peak: 0.075),
    ], shimmer: Shimmer(delay: 0.09, feedback: 0.2, wet: 0.15, lowpass: 3000)),

    .bloom: Recipe(masterGain: 0.5, layers: [
        .tone(.sine, 528, attack: 0.06, decay: 0.32, peak: 0.06),
        .tone(.sine, 528, detune: 12, attack: 0.06, decay: 0.34, peak: 0.05),
    ], shimmer: Shimmer(delay: 0.15, feedback: 0.2, wet: 0.12, lowpass: 2500)),

    .whisper: Recipe(masterGain: 0.48, layers: [
        .noise(.lowpass, 1600, q: 0.7, attack: 0.025, decay: 0.13, peak: 0.04),
        .tone(.sine, 880, offset: 0.01, glideTo: 660, glideTime: 0.14, attack: 0.012, decay: 0.14, peak: 0.025),
    ]),

    .tick: Recipe(masterGain: 0.4, layers: [
        .noise(.bandpass, 5400, q: 1.8, attack: 0.001, decay: 0.018, peak: 0.14),
        .tone(.sine, 2600, attack: 0.001, decay: 0.012, peak: 0.018),
    ]),

    .press: Recipe(masterGain: 0.4, layers: [
        .noise(.bandpass, 1700, q: 1.4, attack: 0.001, decay: 0.02, peak: 0.13),
    ]),

    .release: Recipe(masterGain: 0.4, layers: [
        .noise(.bandpass, 4600, q: 1.8, attack: 0.001, decay: 0.016, peak: 0.12),
        .tone(.sine, 3200, offset: 0.006, attack: 0.001, decay: 0.05, peak: 0.02),
    ]),

    .toggle: Recipe(masterGain: 0.4, layers: [
        .noise(.bandpass, 2200, q: 1.6, attack: 0.001, decay: 0.016, peak: 0.12),
        .noise(.bandpass, 3800, q: 1.6, offset: 0.024, attack: 0.001, decay: 0.02, peak: 0.1),
    ]),

    .success: Recipe(masterGain: 0.5, layers: [
        .tone(.sine, 880, attack: 0.004, decay: 0.09, peak: 0.06),
        .tone(.sine, 1108.73, offset: 0.06, attack: 0.004, decay: 0.1, peak: 0.06),
        .tone(.sine, 1318.51, offset: 0.12, attack: 0.004, decay: 0.18, peak: 0.07),
    ], shimmer: Shimmer(delay: 0.1, feedback: 0.22, wet: 0.16, lowpass: 4500)),

    .error: Recipe(masterGain: 0.42, layers: [
        .noise(.bandpass, 850, q: 1.1, attack: 0.001, decay: 0.035, peak: 0.13),
        .tone(.triangle, 440, offset: 0.025, attack: 0.004, decay: 0.09, peak: 0.045),
        .tone(.triangle, 349.23, offset: 0.1, attack: 0.004, decay: 0.14, peak: 0.04),
    ]),

    .page: Recipe(masterGain: 0.38, layers: [
        .noise(.lowpass, 1800, q: 0.7, attack: 0.006, decay: 0.08, peak: 0.11),
        .noise(.bandpass, 4200, q: 1.2, offset: 0.04, attack: 0.004, decay: 0.065, peak: 0.08),
        .tone(.sine, 2400, offset: 0.075, attack: 0.002, decay: 0.045, peak: 0.02),
    ]),

    .loading: Recipe(masterGain: 0.42, layers: [
        .noise(.lowpass, 1400, q: 0.6, attack: 0.035, decay: 0.14, peak: 0.035),
        .tone(.sine, 420, glideTo: 630, glideTime: 0.18, attack: 0.025, decay: 0.18, peak: 0.05),
    ], shimmer: Shimmer(delay: 0.11, feedback: 0.18, wet: 0.12, lowpass: 2800)),

    .ready: Recipe(masterGain: 0.48, layers: [
        .noise(.bandpass, 3600, q: 1.8, attack: 0.001, decay: 0.02, peak: 0.11),
        .tone(.triangle, 330, offset: 0.012, glideTo: 660, glideTime: 0.12, attack: 0.004, decay: 0.16, peak: 0.055),
        .tone(.sine, 990, offset: 0.13, attack: 0.004, decay: 0.22, peak: 0.06),
    ], shimmer: Shimmer(delay: 0.1, feedback: 0.16, wet: 0.1, lowpass: 4200)),

    .pulse: Recipe(masterGain: 0.42, layers: [
        .noise(.bandpass, 2600, q: 2.4, attack: 0.001, decay: 0.022, peak: 0.08),
        .tone(.triangle, 620, glideTo: 1240, glideTime: 0.07, attack: 0.002, decay: 0.085, peak: 0.055),
    ]),

    .scan: Recipe(masterGain: 0.4, layers: [
        .tone(.sine, 740, attack: 0.002, decay: 0.055, peak: 0.05),
        .tone(.sine, 1110, offset: 0.045, attack: 0.002, decay: 0.055, peak: 0.045),
        .tone(.sine, 1665, offset: 0.09, attack: 0.002, decay: 0.07, peak: 0.04),
    ], shimmer: Shimmer(delay: 0.065, feedback: 0.16, wet: 0.1, lowpass: 4200)),

    .arrival: Recipe(masterGain: 0.44, layers: [
        .noise(.lowpass, 900, q: 0.8, attack: 0.05, decay: 0.24, peak: 0.035),
        .tone(.sine, 220, glideTo: 440, glideTime: 0.32, attack: 0.04, decay: 0.34, peak: 0.055),
        .tone(.sine, 659.25, offset: 0.12, attack: 0.045, decay: 0.32, peak: 0.04),
        .tone(.sine, 987.77, offset: 0.19, attack: 0.045, decay: 0.34, peak: 0.032),
    ], shimmer: Shimmer(delay: 0.16, feedback: 0.28, wet: 0.18, lowpass: 3200)),
]

// MARK: - Synth engine  (mirrors audio/engine.js)

enum CuelumeSynth {
    static let outputGain = 4.0
    static let stopPad = 0.05
    static let cleanupMargin = 0.05

    static func render(_ recipe: Recipe, sampleRate fs: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let dur = sourceEnd(recipe) + shimmerTail(recipe.shimmer) + cleanupMargin
        let n = max(1, Int((dur * fs).rounded(.up)))
        var mix = [Double](repeating: 0, count: n)   // sum of layers (pre-masterGain)

        var rng: UInt64 = 0x9E3779B97F4A7C15    // deterministic noise
        func white() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(Int64(bitPattern: rng)) / Double(Int64.max)
        }

        for layer in recipe.layers {
            let start = Int((layer.offset * fs).rounded())
            let last = layer.attack + layer.decay
            var phase = 0.0
            var biquad = Biquad(layer: layer, fs: fs)
            var i = 0
            while true {
                let tau = Double(i) / fs
                if tau > last { break }
                let idx = start + i; i += 1
                guard idx >= 0 && idx < n else { continue }
                let e = env(tau, layer.attack, layer.decay, layer.peak)
                var s: Double
                if layer.kind == .tone {
                    let f = freq(layer, tau) * pow(2, layer.detune / 1200)
                    s = wave(layer.wave, phase)
                    phase += f / fs
                } else {
                    s = biquad.process(white())
                }
                mix[idx] += s * e
            }
        }

        // master gain, shimmer (feedback delay), output gain, compressor
        let mg = recipe.masterGain
        var out = [Double](repeating: 0, count: n)
        if let sh = recipe.shimmer {
            let d = max(1, Int((sh.delay * fs).rounded()))
            var line = [Double](repeating: 0, count: d)
            var w = 0
            var fb = FeedbackLowpass(cutoff: sh.lowpass, fs: fs)
            for i in 0..<n {
                let m = mix[i] * mg
                let delayed = line[w]
                let filtered = fb.process(delayed)
                out[i] = m + filtered * sh.wet
                line[w] = m + filtered * sh.feedback
                w = (w + 1) % d
            }
        } else {
            for i in 0..<n { out[i] = mix[i] * mg }
        }

        var comp = Compressor(fs: fs)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let ch = buffer.floatChannelData![0]
        for i in 0..<n { ch[i] = Float(comp.process(out[i] * outputGain)) }
        return buffer
    }

    // envelope: 0.0001 →peak (attack) →0.0001 (decay), exponential like Web Audio
    static func env(_ tau: Double, _ a: Double, _ d: Double, _ peak: Double) -> Double {
        let floor = 0.0001
        if tau <= a { return a <= 0 ? peak : floor * pow(peak / floor, tau / a) }
        let td = tau - a
        if td <= d { return d <= 0 ? floor : peak * pow(floor / peak, td / d) }
        return 0
    }

    static func freq(_ l: Layer, _ tau: Double) -> Double {
        guard let to = l.glideTo else { return l.frequency }
        let gt = l.glideTime ?? (l.attack + l.decay)
        if gt <= 0 || tau >= gt { return to }
        return l.frequency * pow(to / l.frequency, tau / gt)   // exponential ramp
    }

    static func wave(_ w: Layer.Wave, _ phase: Double) -> Double {
        switch w {
        case .sine: return sin(2 * .pi * phase)
        case .triangle: let t = phase - floor(phase); return 4 * abs(t - 0.5) - 1
        }
    }

    static func sourceEnd(_ r: Recipe) -> Double {
        r.layers.map { $0.offset + $0.attack + $0.decay + stopPad }.max() ?? 0
    }
    static func shimmerTail(_ s: Shimmer?) -> Double {
        guard let s = s, s.feedback > 0 else { return 0 }
        if s.feedback >= 1 { return s.delay }
        return s.delay * (1 + ceil(log(0.0001) / log(s.feedback)))
    }
}

// RBJ biquad matching Web Audio BiquadFilterNode (LP/HP use Q in dB; BP uses linear Q).
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    var passthrough = true

    init(layer: Layer, fs: Double) {
        guard layer.kind == .noise else { return }
        passthrough = false
        let w0 = 2 * .pi * layer.filterFrequency / fs
        let cw = cos(w0), sw = sin(w0)
        switch layer.filter {
        case .lowpass:
            let alpha = sw / (2 * pow(10, layer.filterQ / 20))   // Web Audio: Q in dB for LP/HP
            let a0 = 1 + alpha
            b0 = (1 - cw) / 2 / a0; b1 = (1 - cw) / a0; b2 = b0
            a1 = -2 * cw / a0; a2 = (1 - alpha) / a0
        case .bandpass:
            let alpha = sw / (2 * layer.filterQ)                 // linear Q for BP
            let a0 = 1 + alpha
            b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
            a1 = -2 * cw / a0; a2 = (1 - alpha) / a0
        }
    }
    mutating func process(_ x: Double) -> Double {
        if passthrough { return x }
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

struct FeedbackLowpass {   // one-pole LP inside the shimmer feedback loop
    var a = 0.0, z = 0.0
    init(cutoff: Double, fs: Double) { a = exp(-2 * .pi * cutoff / fs) }
    mutating func process(_ x: Double) -> Double { z = x * (1 - a) + z * a; return z }
}

struct Compressor {   // soft-knee limiter ≈ shared DynamicsCompressor
    let threshold = -8.0, knee = 6.0, ratio = 12.0
    let atk: Double, rel: Double
    var gain = 1.0
    init(fs: Double) {
        atk = 1 - exp(-1 / (0.002 * fs))
        rel = 1 - exp(-1 / (0.08 * fs))
    }
    mutating func process(_ x: Double) -> Double {
        let level = 20 * log10(max(abs(x), 1e-9))
        let over = level - threshold
        var reduction = 0.0
        if over >= knee / 2 { reduction = over * (1 - 1 / ratio) }
        else if over > -knee / 2 {
            reduction = (1 - 1 / ratio) * pow(over + knee / 2, 2) / (2 * knee)
        }
        let target = pow(10, -reduction / 20)
        gain += (target < gain ? atk : rel) * (target - gain)
        return x * gain
    }
}
