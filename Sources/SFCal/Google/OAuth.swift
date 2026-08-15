import Foundation

enum SFError: Error, CustomStringConvertible {
    case auth(String)
    case http(Int, String)
    case gone
    case noToken(String)

    var description: String {
        switch self {
        case .auth(let m): return "auth: \(m)"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .gone: return "syncToken expirado (410)"
        case .noToken(let l): return "sin token para \(l)"
        }
    }
}

struct TokenFile: Codable {
    let client_id: String
    let client_secret: String
    let refresh_token: String
    let token_uri: String?
    let account: String?
}

/// Sesion OAuth de una cuenta. El token file (~/.sfcal/token-<label>.json) trae
/// client_id/secret adentro: el refresh no necesita nada mas.
actor OAuthSession {
    nonisolated let label: String
    nonisolated let email: String
    private let file: TokenFile
    private var accessToken: String?
    private var expiry: Date = .distantPast

    init?(label: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sfcal/token-\(label).json")
        guard let data = try? Data(contentsOf: url),
              let tf = try? JSONDecoder().decode(TokenFile.self, from: data) else { return nil }
        self.label = label
        self.file = tf
        self.email = tf.account ?? label
    }

    func token() async throws -> String {
        if let t = accessToken, expiry > Date().addingTimeInterval(60) { return t }
        var req = URLRequest(url: URL(string: file.token_uri ?? "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = [
            "client_id=\(file.client_id)",
            "client_secret=\(file.client_secret)",
            "refresh_token=\(file.refresh_token)",
            "grant_type=refresh_token",
        ].joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw SFError.auth("refresh \(label) fallo (HTTP \(code)): \(msg.prefix(160))")
        }
        struct R: Codable { let access_token: String; let expires_in: Double }
        let r = try JSONDecoder().decode(R.self, from: data)
        accessToken = r.access_token
        expiry = Date().addingTimeInterval(r.expires_in)
        return r.access_token
    }
}
