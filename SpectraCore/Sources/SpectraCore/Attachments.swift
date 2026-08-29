import Foundation

/// File attachments (spec §2.6, wire-verified live). Two steps:
///   1. REST upload the data-url → server writes it into the profile's images/
///      dir and returns its server-local `path`.
///   2. Caller stages it on the open session via the `image.attach` RPC
///      (session_id + path); the next prompt.submit then carries it.
public enum Attachments {
    /// Ceiling on what we will base64 into a request body. A data-url upload
    /// costs ~1.4x the file in RAM no matter how carefully it is assembled, so
    /// oversized input is refused with a message rather than OOM-killing the app.
    public static let maxUploadBytes = 32 * 1024 * 1024

    /// `{"data_url":"data:<mime>;base64,<…>","filename":"<name>"}` assembled
    /// directly into Data.
    ///
    /// The obvious route — build a Swift String, hand it to JSONSerialization —
    /// holds three copies of the payload at once (base64 String, the dictionary's
    /// retained value, the serialized body), i.e. ~4x the file. base64 output is
    /// already JSON-safe, so it can be appended verbatim; only the filename needs
    /// escaping, and that is small.
    static func dataURLBody(data: Data, filename: String, mime: String) throws -> Data {
        guard data.count <= maxUploadBytes else {
            throw HermesAuthError.httpError(-1, "file is too large to upload")
        }
        var body = Data(#"{"data_url":"data:"#.utf8)
        body.append(contentsOf: mime.utf8)
        body.append(contentsOf: ";base64,".utf8)
        body.append(data.base64EncodedData())     // Data, not String: one copy fewer
        body.append(contentsOf: #"","filename":"#.utf8)
        body.append(try JSONEncoder().encode(filename))   // quoted + escaped
        body.append(contentsOf: "}".utf8)
        return body
    }

    /// POST /api/chat/image-upload?profile=<name>  → returns the server `path`.
    /// Verified response: { ok, bytes, mime_type, path, name }.
    public static func upload(baseURL: URL, token: String, profile: String,
                              data: Data, filename: String, mime: String) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "api/chat/image-upload")
            .appending(queryItems: [.init(name: "profile", value: profile)]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try dataURLBody(data: data, filename: filename, mime: mime)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let path = json["path"] as? String
        else { throw HermesAuthError.httpError((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                               "image upload failed") }
        return path
    }
}
