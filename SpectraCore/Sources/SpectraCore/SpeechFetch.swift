import Foundation

/// Server-side text-to-speech through Hermes.
///
/// Verified endpoint: `POST /api/audio/speak` with `{"text": "…"}` returns
/// `{ ok, data_url: "data:audio/mpeg;base64,…", mime_type, provider }` — the
/// same base64 data-URL shape `/api/media` uses, and Bearer-auth-gated like the
/// rest of the REST surface. With `tts.provider: elevenlabs` in Hermes'
/// config.yaml the bytes come back as MP3 (`mp3_44100_128`).
///
/// The audio is only *fetched* here; decoding and playback stay in the caller
/// so the samples can be scheduled on Voice Mode's own audio engine, which is
/// what lets echo cancellation (and therefore barge-in) work.
public enum SpeechFetch {

    /// Network synthesis sits directly in the turn-taking loop, so a stalled
    /// request is a silent Voice Mode. Fail fast and let the caller fall back
    /// to on-device speech instead.
    public static let timeout: TimeInterval = 15

    public static func audio(text: String, baseURL: URL, token: String,
                             session: URLSession = .shared) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: "api/audio/speak"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 { throw HermesAuthError.sessionExpired }
            throw HermesAuthError.httpError(http.statusCode, "speech synthesis failed")
        }
        struct Wrapper: Decodable { let data_url: String }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        guard let bytes = decodeDataURL(wrapper.data_url) else {
            throw HermesAuthError.httpError(-1, "bad audio data_url")
        }
        return bytes
    }

    /// `data:<mime>;base64,<payload>` → raw bytes.
    ///
    /// Anchored on the `base64,` marker rather than the first comma, so a mime
    /// section carrying its own comma (`;codecs=a,b`) can't truncate the
    /// payload. Only base64 data URLs are accepted — that is all this endpoint
    /// emits, and a silently mis-parsed URL would surface as unexplained
    /// silence rather than an error.
    static func decodeDataURL(_ value: String) -> Data? {
        guard let marker = value.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(value[marker.upperBound...]))
    }
}
