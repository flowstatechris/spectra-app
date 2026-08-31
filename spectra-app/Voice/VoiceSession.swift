import AVFoundation
import Foundation
import Observation
import Speech
import SpectraCore

/// Voice Mode's state machine: microphone → on-device transcription → the
/// existing text RPC → on-device speech synthesis.
///
/// It *observes* a `ProfileSession` rather than owning conversation state —
/// every voice turn lands in the same `messages` timeline a typed turn does, so
/// leaving Voice Mode leaves a normal chat behind. Nothing new goes on the
/// wire: the connection still carries text in both directions.
@MainActor
@Observable
final class VoiceSession {

    enum Phase: Equatable { case idle, listening, sending, thinking, speaking }

    /// Silence after speech that ends the user's turn.
    ///
    /// This is the single largest term in the perceived-latency budget, so it is
    /// the first knob to reach for if the loop feels sluggish, and deliberately
    /// a named constant rather than a literal buried in the endpoint task.
    static let endpointSilence: Duration = .milliseconds(800)

    /// How long the microphone gets to prove it is alive before we conclude
    /// that voice processing broke it. See `startEngine`.
    private static let micLivenessDeadline: Duration = .milliseconds(1500)

    private(set) var phase: Phase = .idle
    /// Live (volatile) transcription of what the user is saying right now.
    private(set) var partialTranscript = ""
    /// The sentence currently being spoken, for the caption under the orb.
    private(set) var captionText = ""
    private(set) var error: String?

    let session: ProfileSession

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = VoiceSession.bestInstalledVoice()
    /// Server-side synthesis (Hermes → ElevenLabs). Injected by the view, which
    /// is where AppState lives. When it is nil or fails, `speak` falls back to
    /// the on-device synthesiser rather than going quiet.
    var remoteSynthesize: ((String) async -> Data?)?
    /// Which engine produced the last sentence, for the debug readout.
    private(set) var lastEngine = ""
    /// True when the best voice on this device is a compact one. iOS ships only
    /// compact voices by default; the good ones (Enhanced/Premium) are a free
    /// download the user has to opt into, and until they do everything sounds
    /// robotic no matter what we do at this layer.
    var usingCompactVoice: Bool { (voice?.quality ?? .default) == .default }

    /// The mixer's real output format, read from the graph after the audio
    /// session is live. Synthesised audio is converted into this rather than
    /// asserting a format on the connection — asserting one is what made an
    /// earlier build play deafening warbled static.
    private var playbackFormat: AVAudioFormat?

    /// True when the engine granted hardware echo cancellation. It gates the
    /// whole barge-in feature: with AEC the mic can stay open while we speak;
    /// without it, an open mic transcribes our own voice and the agent
    /// interrupts itself in a loop.
    private var echoCancelled = false

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    private var chunker = SentenceChunker()
    private var sentences: AsyncStream<(generation: Int, text: String)>.Continuation?
    private var speakingTask: Task<Void, Never>?
    /// Bumped on every barge-in and every new turn. Sentences synthesised for an
    /// older generation are dropped instead of played over the new turn.
    private var generation = 0

    private var endpointTask: Task<Void, Never>?
    private var idleFlushTask: Task<Void, Never>?
    private var micWatchdog: Task<Void, Never>?
    /// Finalised transcript segments for the utterance in progress; volatile
    /// results are appended for display only.
    private var utterance = ""
    /// Set when the user talks over a reply, consumed by the next submit so
    /// Hermes latches `mark_speech_interrupted()` for that turn.
    private var didBargeIn = false
    private var interruptionObserver: NSObjectProtocol?
    /// Voice Mode exited on its own (a call came in), so the view dismisses.
    private(set) var didExit = false

    /// Live audio-graph facts, debug builds only. Several rounds of this feature
    /// went to guessing at things the device could simply have been asked for.
    private(set) var graphSummary = ""
    private(set) var micBufferCount = 0
    var diagnostics: String {
        graphSummary.isEmpty ? "" : "\(graphSummary) · mic \(micBufferCount)"
            + (lastEngine.isEmpty ? "" : " · tts \(lastEngine)")
    }

    init(session: ProfileSession) { self.session = session }

    // MARK: Lifecycle

    func start() async {
        guard phase == .idle else { return }
        do {
            try await requestPermissions()
            // UI cues would be picked up by the mic, and our category change
            // takes the cue engine's IO out from under it either way.
            Cuelume.shared.suspendForExclusiveAudio()
            try configureAudioSession()
            observeInterruptions()
            try await startTranscription()
            try startEngine()
            tapAgentStream()
            phase = .listening
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        endpointTask?.cancel(); endpointTask = nil
        idleFlushTask?.cancel(); idleFlushTask = nil
        micWatchdog?.cancel(); micWatchdog = nil
        resultsTask?.cancel(); resultsTask = nil
        speakingTask?.cancel(); speakingTask = nil
        sentences?.finish(); sentences = nil

        session.onAgentDelta = nil
        session.onTurnEnd = nil

        analyzerInput?.finish(); analyzerInput = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil; transcriber = nil

        synthesizer.stopSpeaking(at: .immediate)
        // removeTap is idempotent, and a start() that failed halfway can leave a
        // tap on a stopped engine — so don't gate the teardown on isRunning.
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }

        // Hand the session back the way Cuelume expects to find it, then let it
        // re-prove warmth against the session it actually has now.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        Cuelume.shared.resumeAfterExclusiveAudio()

        playbackFormat = nil; converter = nil; playbackConverter = nil
        graphSummary = ""; micBufferCount = 0; lastEngine = ""
        partialTranscript = ""; captionText = ""; utterance = ""
        phase = .idle
    }

    // MARK: Audio session

    private func requestPermissions() async throws {
        if await AVAudioApplication.requestRecordPermission() == false {
            throw VoiceError.microphoneDenied
        }
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speech == .authorized else { throw VoiceError.speechDenied }
    }

    /// `.voiceChat` asks the system for a duplex, echo-cancelled route. It is
    /// also what lets us record and play at once at all — Cuelume's `.ambient`
    /// category cannot record and is silenced by the mute switch.
    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .allowBluetooth])
        try s.setActive(true)
    }

    /// A phone or FaceTime call takes the session out from under us. Exit
    /// cleanly and do not auto-resume — coming back mid-call is exactly the
    /// path that has crashed this app before (see Cuelume's `isWarm` notes).
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stop()
                self.didExit = true
            }
        }
    }

    // MARK: Audio graph

    /// Builds the graph with echo cancellation, then *checks that the mic
    /// actually works* and rebuilds without it if not.
    ///
    /// `setVoiceProcessingEnabled(true)` is the only way to get AEC on an
    /// `AVAudioEngine`, and AEC is the only thing that makes barge-in possible.
    /// But on this graph it has previously killed the microphone outright —
    /// indicator lit, then dark, and the tap delivered zero buffers with no
    /// error thrown anywhere. Rather than choose blind between "barge-in" and
    /// "a mic that works", ask for AEC and verify: if no buffers arrive inside
    /// `micLivenessDeadline`, tear the graph down and rebuild it plain.
    private func startEngine() throws {
        try buildGraph(voiceProcessing: true)

        micWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.micLivenessDeadline)
            guard !Task.isCancelled, let self,
                  self.echoCancelled, self.micBufferCount == 0 else { return }
            // Voice processing swallowed the microphone. Barge-in is worth
            // losing; a session that cannot hear the user is not.
            try? self.buildGraph(voiceProcessing: false)
        }
    }

    private func buildGraph(voiceProcessing: Bool) throws {
        let input = engine.inputNode

        // Tearing down first makes this callable as a rebuild, not just a
        // first-time setup. Toggling voice processing requires a stopped engine.
        input.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        // Input only: the VPIO unit covers both directions, and enabling it on
        // the output node as well is one more way for setup to fail.
        do {
            try input.setVoiceProcessingEnabled(voiceProcessing)
            echoCancelled = voiceProcessing
        } catch {
            echoCancelled = false
        }

        if player.engine == nil { engine.attach(player) }

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard mixerFormat.sampleRate > 0 else { throw VoiceError.audioGraph("speaker") }
        playbackFormat = mixerFormat
        playbackConverter = nil          // formats may have changed under us
        engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceError.audioGraph("microphone")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.feedTranscriber(buffer)
        }

        engine.prepare()
        try engine.start()

        graphSummary = "mic \(Int(inputFormat.sampleRate))Hz · out \(Int(mixerFormat.sampleRate))Hz"
            + " · aec \(echoCancelled ? "on" : "off")"
            + " · \(voice?.name ?? "system") \(Self.qualityLabel(voice?.quality))"
    }

    // MARK: Transcription

    private func startTranscription() async throws {
        let locale = Locale.current
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw VoiceError.transcriberUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        // First run may need the on-device speech model installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerInput = continuation
        try await analyzer.start(inputSequence: stream)

        self.transcriber = transcriber
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            guard let results = self?.transcriber?.results else { return }
            do {
                for try await result in results {
                    await self?.handle(result)
                }
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
        }
    }

    private nonisolated func feedTranscriber(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self, let target = self.analyzerFormat else { return }
            self.micBufferCount += 1
            // With AEC the mic stays open while we speak, which is what makes
            // barge-in possible. Without it, listening while speaking means
            // transcribing our own voice — so gate instead, and lose barge-in.
            guard self.echoCancelled || self.phase != .speaking else { return }
            guard let converted = self.convert(buffer, to: target, using: &self.converter)
            else { return }
            self.analyzerInput?.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// One-shot format conversion, reused by both the mic and playback paths.
    /// The converter is cached per caller and rebuilt whenever either side's
    /// format changes.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat,
                         using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        // Barge-in fires on *words*, never on raw input level — a cough or a
        // door must not kill a turn the user wanted to hear.
        if phase == .speaking { bargeIn() }

        if result.isFinal {
            utterance = (utterance.isEmpty ? text : utterance + " " + text)
            partialTranscript = utterance
        } else {
            partialTranscript = utterance.isEmpty ? text : utterance + " " + text
        }
        scheduleEndpoint()
    }

    private func scheduleEndpoint() {
        endpointTask?.cancel()
        endpointTask = Task { [weak self] in
            try? await Task.sleep(for: Self.endpointSilence)
            guard !Task.isCancelled else { return }
            await self?.commitUtterance()
        }
    }

    private func commitUtterance() async {
        let text = (utterance.isEmpty ? partialTranscript : utterance)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        utterance = ""; partialTranscript = ""
        guard !text.isEmpty else { return }

        // An approval hard-blocks sending and is resolved by tap, never by
        // voice — see VoiceModeView. Drop the utterance rather than queue it
        // against a blocked session.
        guard session.pendingApproval == nil else { return }

        phase = .sending
        generation += 1
        chunker = SentenceChunker()

        if let clarify = session.pendingClarify {
            // Clarify is soft, so the natural thing to do with speech is answer
            // it rather than start a new turn that ignores the question.
            await session.answerClarify(questionID: clarify.questions.first?.id ?? "",
                                        answer: text)
        } else {
            let interrupted = didBargeIn
            didBargeIn = false
            await session.send(text, interrupted: interrupted)
        }
        phase = .thinking
    }

    /// The user talked over the reply: stop speaking, tell Hermes, and let the
    /// next submit carry `interrupted: true` so the model knows it was cut off.
    private func bargeIn() {
        didBargeIn = true
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        captionText = ""
        chunker = SentenceChunker()
        Task { await session.interrupt() }
    }

    // MARK: Agent text → speech

    private func tapAgentStream() {
        let (stream, continuation) = AsyncStream<(generation: Int, text: String)>.makeStream()
        sentences = continuation
        speakingTask = Task { [weak self] in
            for await item in stream {
                guard let self, !Task.isCancelled else { return }
                guard item.generation == self.generation else { continue }  // stale turn
                await self.speak(item.text, generation: item.generation)
            }
        }

        session.onAgentDelta = { [weak self] delta in
            guard let self else { return }
            for sentence in self.chunker.feed(delta) {
                self.sentences?.yield((self.generation, sentence))
            }
            self.scheduleIdleFlush()
        }
        session.onTurnEnd = { [weak self] in
            guard let self else { return }
            self.idleFlushTask?.cancel()
            for sentence in self.chunker.flush() {
                self.sentences?.yield((self.generation, sentence))
            }
        }
    }

    /// A narration line spoken before a long tool call shouldn't be held to
    /// end-of-turn, so a quiet producer flushes the buffer too.
    private func scheduleIdleFlush() {
        idleFlushTask?.cancel()
        idleFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.chunker.hasPendingText else { return }
            for sentence in self.chunker.flush() {
                self.sentences?.yield((self.generation, sentence))
            }
        }
    }

    private func speak(_ text: String, generation: Int) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = playbackFormat else { return }

        // Whichever engine synthesises it, the audio is decoded to PCM and
        // played through our own engine. Handing it to AVSpeechSynthesizer's
        // `speak(_:)` or to AVAudioPlayer would put it on a path we don't own,
        // which both defeats echo cancellation (the VPIO unit references *our*
        // output) and takes away frame-accurate interruption.
        var buffer: AVAudioPCMBuffer?
        if let remote = remoteSynthesize, let encoded = await remote(text) {
            buffer = decode(encoded, into: target)
            if buffer != nil { lastEngine = "hermes" }
        }
        if buffer == nil {
            // Network TTS failed or isn't wired: a robotic voice beats silence.
            buffer = merge(await render(text), into: target)
            lastEngine = buffer == nil ? "failed" : "on-device"
        }
        guard let buffer, generation == self.generation else { return }

        captionText = text
        phase = .speaking
        if !player.isPlaying { player.play() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Also fires when player.stop() flushes the queue on barge-in, so
            // this never strands the consumer loop.
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                cont.resume()
            }
        }
        if generation == self.generation, phase == .speaking {
            captionText = ""
            phase = .listening
        }
    }

    /// Compressed audio (MP3 from Hermes) → PCM in the mixer's format.
    ///
    /// `AVAudioFile` is the decoder here because it handles every container
    /// CoreAudio knows without us parsing headers, and it needs a file on disk
    /// — hence the temp file, removed on the way out whatever happens.
    private func decode(_ encoded: Data, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tts-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? encoded.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil
        else { return nil }
        return convert(source, to: format, using: &playbackConverter)
    }

    /// Synthesise one utterance into PCM. `write` calls back with a zero-length
    /// buffer when it is done; markers and non-PCM buffers are ignored.
    private func render(_ text: String) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return await withCheckedContinuation { cont in
            let sink = RenderSink(cont)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { sink.finish() } else { sink.append(pcm) }
            }
        }
    }

    /// Concatenate the rendered chunks into a single buffer in the mixer's
    /// format, so one `scheduleBuffer` completion means "the sentence is done".
    private func merge(_ buffers: [AVAudioPCMBuffer],
                       into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let converted = buffers.compactMap { convert($0, to: format, using: &playbackConverter) }
        guard !converted.isEmpty else { return nil }
        let frames = converted.reduce(0) { $0 + $1.frameLength }
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dst = out.floatChannelData
        else { return nil }

        let channels = Int(format.channelCount)
        var offset = 0
        for piece in converted {
            guard let src = piece.floatChannelData else { continue }
            let count = Int(piece.frameLength)
            for ch in 0..<channels {
                dst[ch].advanced(by: offset).update(from: src[ch], count: count)
            }
            offset += count
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality?) -> String {
        switch quality {
        case .premium: "(premium)"
        case .enhanced: "(enhanced)"
        default: "(compact)"
        }
    }

    /// Best voice actually installed for the user's language. Enhanced and
    /// premium voices only exist once someone downloads them in Settings →
    /// Accessibility → Spoken Content → Voices, so this has to degrade quietly
    /// rather than assume a nice voice is present.
    private static func bestInstalledVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let rank: (AVSpeechSynthesisVoiceQuality) -> Int = { quality in
            switch quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
        }
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { rank($0.quality) < rank($1.quality) }
        return installed ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Speak text the user didn't ask a question to get — an approval request or
    /// a clarify question. Used by the view when one arrives.
    func announce(_ text: String) {
        sentences?.yield((generation, text))
    }
}

/// Collects `AVSpeechSynthesizer.write` callbacks, which arrive on an arbitrary
/// queue, and resumes its continuation exactly once.
private final class RenderSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        buffers.append(buffer)
    }

    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = buffers
        lock.unlock()
        pending?.resume(returning: result)
    }
}

enum VoiceError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case transcriberUnavailable
    case audioGraph(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Spectra needs microphone access for Voice Mode. Enable it in Settings."
        case .speechDenied: "Spectra needs speech recognition access for Voice Mode. Enable it in Settings."
        case .transcriberUnavailable: "On-device speech recognition isn't available for this language."
        case .audioGraph(let part): "Couldn't set up the \(part) audio path."
        }
    }
}
