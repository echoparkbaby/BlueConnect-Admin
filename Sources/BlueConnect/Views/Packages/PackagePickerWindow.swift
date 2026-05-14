import SwiftUI

/// Window-scene wrapper around `PackagePickerSheet`. Lives in its own
/// resizable + movable NSWindow (unlike the previous `.sheet` flavour
/// that was glued to the parent window). Reads `hosts` from the shared
/// controller and writes install / file-drop intents back to it; the
/// owning `ContentView` reacts via `.onChange`.
struct PackagePickerWindow: View {
    @Environment(PackagePickerController.self) private var picker
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        PackagePickerSheet(
            hosts: picker.hosts,
            onInstall: { pkg in
                picker.pendingDirectInstall = pkg
            },
            onInstallMunki: { pkg in
                picker.pendingMunkiInstall = pkg
            },
            onDropFile: { url in
                picker.pendingFileDrop = url
            }
        )
        .onChange(of: picker.openCounter) { _, _ in
            // No-op — exists so re-presenting the window with new hosts
            // re-renders the embedded picker with the latest selection.
        }
    }
}
