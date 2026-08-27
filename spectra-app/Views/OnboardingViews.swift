import SwiftUI
import AuthenticationServices
import SpectraCore

/// Step 1 (spec §5): backend base-URL entry — editorial cover.
struct BackendConfigView: View {
    @Environment(AppState.self) private var app
    @State private var urlText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("LogoMark")
                .resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(Theme.ink)
            Text("Spectra")
                .font(Theme.serif(52, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)   // hero shrinks to fit at AX sizes, never truncates
                .padding(.top, 18)
            Text("Any Hermes instance. Your phone. One app.")
                .font(Theme.mono(12))
                .tracking(0.4)
                .foregroundStyle(Theme.muted)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Backend")
                TextField("", text: $urlText, prompt:
                    Text("http://10.0.0.182:9119").foregroundStyle(Theme.muted.opacity(0.6)))
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.ink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.vertical, 14).padding(.horizontal, 16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: 1))
            }
            .padding(.top, 56)
            .padding(.horizontal, 28)

            Button("Connect") {
                // Force a scheme BEFORE parsing: URLComponents reads a bare
                // "10.0.0.182:9119" with the host as the scheme, so a
                // scheme==nil check never fires and the URL comes out malformed.
                var s = urlText.trimmingCharacters(in: .whitespaces)
                if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
                    s = "http://" + s
                }
                guard let url = URLComponents(string: s)?.url, url.host != nil else { return }
                app.setBackend(url)
            }
            .buttonStyle(PrimaryButton())
            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(urlText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Spacer(); Spacer()
        }
        .paper()
        .onAppear { focused = true }
    }
}

/// Step 2 (spec §5): system-browser login, orb while brokering.
struct LoginView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            OrbView(status: .connecting, connectionState: .connecting)
            Group {
                if case .loggingIn = app.phase {
                    Eyebrow("Setting up your workspace", color: Theme.accent)
                        .padding(.top, 28)
                } else {
                    VStack(spacing: 14) {
                        Eyebrow("Sign in")
                        Text(app.backend?.displayName ?? "")
                            .font(Theme.serif(28))
                            .foregroundStyle(Theme.ink)
                        Button("Continue with browser") { Task { await signIn() } }
                            .buttonStyle(PrimaryButton())
                            .padding(.horizontal, 40)
                            .padding(.top, 4)
                    }
                    .padding(.top, 28)
                }
            }
            if case .error(let message) = app.phase {
                VStack(spacing: 14) {
                    Text(message)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Try again") { Task { await signIn() } }
                        .buttonStyle(OutlineButton())
                }
                .padding(.top, 24)
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paper()
    }

    private func signIn() async {
        await app.login { url, cancel in
            AuthPresenter.shared.start(url: url, onCancel: cancel)
        }
    }
}

/// Step 3 (spec §5): profile checklist, select-all, explicit add.
struct ProfilePickerView: View {
    @Environment(AppState.self) private var app
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Discovered")
                    Text("Add profiles")
                        .font(Theme.serif(34))
                        .foregroundStyle(Theme.ink)
                }
                Spacer()
                Button(selected.count == app.availableProfiles.count ? "None" : "All") {
                    selected = selected.count == app.availableProfiles.count
                        ? [] : Set(app.availableProfiles.map(\.name))
                }
                .buttonStyle(OutlineButton())
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(app.availableProfiles) { profile in
                        profileRow(profile)
                    }
                }
                .padding(.horizontal, 24)
            }

            Button("Add \(selected.count) profile\(selected.count == 1 ? "" : "s")") {
                app.addProfiles(Array(selected).sorted())
            }
            .buttonStyle(PrimaryButton())
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.4 : 1)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .paper()
    }

    private func profileRow(_ profile: ProfileInfo) -> some View {
        let isOn = selected.contains(profile.name)
        return Button {
            if isOn { selected.remove(profile.name) } else { selected.insert(profile.name) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(Theme.serif(20))
                        .foregroundStyle(Theme.ink)
                    if !profile.model.isEmpty {
                        Text(profile.model)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Theme.accent : Theme.hairline)
            }
            .padding(16)
            .card(border: isOn ? Theme.accent.opacity(0.5) : Theme.hairline)
        }
        .buttonStyle(.plain)
    }
}
