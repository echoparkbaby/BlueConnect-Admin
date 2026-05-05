import SwiftUI

struct LoginView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var auth: AuthGate
    @Environment(BlueSkyHostListStore.self) var hostStore

    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var enableTouchID: Bool = false
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 50))
                .foregroundStyle(.tint)
            Text("BlueConnect Admin")
                .font(.title).bold()
            Text("Sign in to your BlueSky server")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                LabeledTextField(label: "Server URL", text: $url, placeholder: "https://bluesky.example.com")
                LabeledTextField(label: "Username", text: $username, placeholder: "admin")
                LabeledSecureField(label: "Password", text: $password)

                Toggle(isOn: $enableTouchID) {
                    HStack(spacing: 6) {
                        Image(systemName: "touchid").foregroundStyle(.tint)
                        Text("Use Touch ID for future logins")
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!auth.isBiometricsAvailable)
                .padding(.top, 4)
                if !auth.isBiometricsAvailable {
                    Text("Touch ID isn't available on this Mac — your account password will be used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if let m = errorMessage {
                Text(m).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack {
                Spacer()
                Button {
                    Task { await tryLogin() }
                } label: {
                    if checking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                            .frame(minWidth: 120)
                    } else {
                        Text("Sign In").frame(minWidth: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(checking || !canSubmit)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320)
        .onAppear {
            // Pre-populate from any existing settings (e.g. after explicit logout).
            if url.isEmpty { url = settings.apiURL }
            if username.isEmpty { username = settings.apiUsername }
        }
    }

    private var canSubmit: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private func tryLogin() async {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)

        checking = true
        errorMessage = nil
        defer { checking = false }

        // Probe the API with the entered credentials.
        do {
            _ = try await BlueSkyAPI.shared.fetchBlueSkyHosts(
                apiURL: u, username: n, password: p
            )
        } catch {
            let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
            errorMessage = "Sign-in failed:\n\(m)"
            return
        }

        // Persist
        settings.apiURL = u
        settings.apiUsername = n
        settings.webAdminPass = p
        settings.savePasswordToKeychain()
        // Auto-fill the SSH tunnel host from the URL on first sign-in. The
        // user can still override it in Settings if it differs from the
        // HTTP host (e.g. NPM proxies the API but ssh hits a bare hostname).
        if settings.serverFqdn.isEmpty,
           let host = URL(string: u)?.host, !host.isEmpty {
            settings.serverFqdn = host
        }
        auth.onLoginSuccess(enableTouchID: enableTouchID && auth.isBiometricsAvailable)

        // Trigger first refresh
        await hostStore.refresh(settings: settings)
    }
}
