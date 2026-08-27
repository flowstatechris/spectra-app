import AuthenticationServices
import UIKit

/// Presents the login flow in an ASWebAuthenticationSession (in-app browser
/// sheet) instead of bouncing out to Safari — so it auto-dismisses and returns
/// to the app on callback. The loopback server (LoopbackCallbackServer) still
/// catches the real `?code=` redirect and drives token exchange; its response
/// JS-bounces to `spectra://auth-done`, which this session's callbackURLScheme
/// catches to close the sheet. `callbackURLScheme` needs no Info.plist entry.
@MainActor
final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresenter()
    private var session: ASWebAuthenticationSession?

    func start(url: URL, onCancel: @escaping () -> Void) {
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "spectra") { _, error in
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                onCancel()   // user closed the sheet — release the pending loopback
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false   // reuse Safari session for SSO
        session = s
        s.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
