# AVSpeechSynthesizer for Voice Mode TTS, not on-device Kokoro

The Voice Mode spec chose Kokoro-82M via [`mlalma/kokoro-ios`](https://github.com/mlalma/kokoro-ios)
(MLX Swift) for speech synthesis. Built as specified, it produced loud noise on device instead of
speech — while the identical model file, voice file and library version produced clean speech on
macOS. Measured on the same sentence: device peak amplitude **16.4–22.8**, macOS **0.28–0.36**
(expected range is under 1.0). The device also predicted different durations for the same text —
81,000 frames against macOS's 96,600 — so the divergence began before the vocoder, not in playback.

The cause is upstream and not ours. mlx-swift 0.30.2 misdetects the A18 chip as having Neural
Accelerator (NAX) hardware and silently computes wrong numbers ([mlx#3083](https://github.com/ml-explore/mlx/pull/3083)),
and separately overflows in `ConvTransposed1d` for time dimensions above ~8000
([mlx#3092](https://github.com/ml-explore/mlx/pull/3092)) — precisely Kokoro's vocoder. kokoro-ios
issue [#29](https://github.com/mlalma/kokoro-ios/issues/29) reports the same fingerprint: *"sample
values range -11 to +11 instead of the expected -0.33 to +0.54."* macOS is unaffected because the
misdetection is A-series-only. Both bugs are fixed in mlx-swift **0.30.6**.

We cannot take that fix from where we sit. `kokoro-ios` **and** `MisakiSwift` each pin
`exact: "0.30.2"`; an `exact` requirement cannot be overridden by a downstream consumer, neither
package has a release carrying the bump, and the fix PR has been open since March. The only routes
are forking or vendoring both packages and maintaining them.

Decided to use `AVSpeechSynthesizer` instead. The platform already ships an on-device TTS engine,
and taking it removed MLX from the app entirely: no 327MB model download, no 327MB resident
weights, no memory-pressure terminations, no Metal toolchain requirement, and — because MLX was
what pulled in Metal 4 tensor symbols the simulator SDK does not ship — `./run.sh` builds and boots
again. Bundle size fell to ~9MB.

The cost is voice quality: Apple's voices are behind Kokoro's `af_heart`, and enhanced ones only
exist if the user downloads them in Settings → Accessibility → Spoken Content → Voices, so
`VoiceSession.bestInstalledVoice()` degrades quietly to whatever is present.

Synthesis goes through `AVSpeechSynthesizer.write(_:toBufferCallback:)` into our own
`AVAudioEngine`, not `speak(_:)`. Routing the audio through our graph is what lets the
voice-processing I/O unit use it as the echo-cancellation reference, which is what makes barge-in
work at all; it also gives frame-accurate interruption. Because `setVoiceProcessingEnabled(true)`
has previously killed the microphone outright on this graph — indicator lit, then dark, zero tap
buffers, no error thrown — the graph asks for echo cancellation and then verifies it, rebuilding
without it if no audio arrives within 1.5s. Barge-in is live when AEC is granted; when it isn't,
the mic is gated during playback and barge-in is unavailable rather than risking a feedback loop.

Reversing this is contained: re-add `KokoroModel.swift` and change the body of
`VoiceSession.speak(_:generation:)`. Worth doing once kokoro-ios merges #29 or tags a release
built on mlx-swift ≥0.30.6. No TTS-provider protocol was introduced for a single implementation —
that function is already the seam.

## Amendment: ElevenLabs via Hermes is now the primary engine

Apple's compact voices — the only ones iOS installs by default — were judged too robotic in use.
Rather than reopen the Kokoro fork, Voice Mode now synthesises through Hermes'
`POST /api/audio/speak`, which already had a full provider chain built for the Electron desktop
and which the original spec deliberately bypassed to stay on-device.

That trade is reconsidered, not ignored: the reply text already crosses this connection, so
sending the same text to be spoken adds no new class of exposure. What it does add is a network
round trip inside the turn loop, which is why synthesis is per-sentence (the `SentenceChunker`
already cuts them) and why the request has a 15s ceiling.

Backend: `tts.provider: elevenlabs` with `model_id: eleven_flash_v2_5` in `~/.hermes/config.yaml`;
the API key lives in `~/.hermes/.env` (mode 600, outside any git repo) and never in this
repository. `eleven_flash_v2_5` over the `eleven_multilingual_v2` default because per-request
latency *is* the experience here — flash answers in well under a second against two to three.
Note that `_get_provider` defaults to Edge and treats a present API key as insufficient consent
for paid speech, so the config entry — not the key — is what actually selects the provider.

Client: `SpeechFetch` (SpectraCore) fetches the base64 data URL — the same shape `/api/media`
returns — and `VoiceSession.decode(_:into:)` turns the MP3 (`mp3_44100_128`) into PCM via
`AVAudioFile`, converted into the mixer's format and scheduled on the same `AVAudioPlayerNode`
as before. Keeping playback inside our own `AVAudioEngine` is not incidental: the voice-processing
unit cancels echo against our output, so audio played anywhere else would break barge-in.

`AVSpeechSynthesizer` remains as an automatic fallback whenever the request fails, because a
network problem should cost voice quality, not the reply. The debug line reports which engine
spoke (`hermes` / `on-device`), and the compact-voice hint now appears only on the fallback path.

Kokoro's re-entry condition is unchanged, and the seam is still the body of
`VoiceSession.speak(_:generation:)`.
