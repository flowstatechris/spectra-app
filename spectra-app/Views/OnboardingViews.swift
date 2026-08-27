import SwiftUI
import AuthenticationServices
import SpectraCore

/// Step 1 (spec §5): backend base-URL entry.
struct BackendConfigView: View {
    @Environment(AppState.self) private var app
    @State private var urlText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text("Spectra")
                .font(.largeTitle.bold())
            Text("Any Hermes instance. Your phone. One app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("http://your-hermes-host:9119", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 32)
            Button("Connect") {
                guard var comps = URLComponents(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
                if comps.scheme == nil { comps.scheme = "http" }
                if let url = comps.url { app.setBackend(url) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            Spacer()
        }
        .onAppear { focused = true }
    }
}

/// Step 2 (spec §5): system-browser login with orb spinner while brokering.
struct LoginView: View {
    @Environment(AppState.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            OrbView(status: .connecting, connectionState: .connecting)
            if case .loggingIn = app.phase {
                Text("Setting up your workspace")
                    .font(.headline)
            } else {
                Text(app.backend?.displayName ?? "")
                    .font(.headline)
                Button("Sign in") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
            }
            if case .error(let message) = app.phase {
                VStack(spacing: 12) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try again") { Task { await signIn() } }
                }
            }
            Spacer()
            Spacer()
        }
    }

    private func signIn() async {
        await app.login { url in
            // RFC 8252: real system-browser context. ASWebAuthenticationSession
            // with an http callback isn't usable; the loopback listener catches
            // the redirect, so plain open is correct here.
            UIApplication.shared.open(url)
        }
    }
}

/// Step 3 (spec §5): checklist of discovered profiles, select-all, explicit add.
struct ProfilePickerView: View {
    @Environment(AppState.self) private var app
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(app.availableProfiles, selection: $selected) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body)
                    if !profile.model.isEmpty {
                        Text(profile.model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(profile.name)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Add profiles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select all") { selected = Set(app.availableProfiles.map(\.name)) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { app.addProfiles(Array(selected).sorted()) }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }
}
