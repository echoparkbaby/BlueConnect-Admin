import SwiftUI

struct LockView: View {
    @EnvironmentObject var auth: AuthGate
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("BlueConnect Admin")
                .font(.title2).bold()
            Text(settings.apiUsername.isEmpty ? "Locked" : "Locked — \(settings.apiUsername)")
                .foregroundStyle(.secondary)
            Button {
                Task { await auth.unlockWithTouchID() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button("Sign Out") {
                auth.logout(settings: settings)
            }
            .buttonStyle(.link)
            .padding(.top, 4)

            if let err = auth.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320)
        .task { await auth.unlockWithTouchID() }
    }
}
