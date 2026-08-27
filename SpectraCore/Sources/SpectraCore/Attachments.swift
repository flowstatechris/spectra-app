import Foundation

/// File attachments (spec §2.6, wire-verified live). Two steps:
///   1. REST upload the data-url → server writes it into the profile's images/
///      dir and returns its server-local `path`.
///   2. Caller stages it on the open session via the `image.attach` RPC
///      (session_id + path); the next prompt.submit then carries it.
public enum Attachments {
    /// POST /api/chat/image-upload?profile=<name>  → returns the server `path`.
    /// Verified response: { ok, bytes, mime_type, path, name }.
    public static func upload(baseURL: URL, token: String, profile: String,
                              data: Data, filename: String, mime: String) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "api/chat/image-upload")
            .appending(queryItems: [.init(name: "profile", value: profile)]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["data_url": dataURL,
                                                                   "filename": filename])
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let path = json["path"] as? String
        else { throw HermesAuthError.httpError((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                               "image upload failed") }
        return path
    }
}
