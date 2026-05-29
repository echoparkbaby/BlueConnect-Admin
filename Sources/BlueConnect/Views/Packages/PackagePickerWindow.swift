import SwiftUI
import AppKit

/// Window-scene wrapper around `PackagePickerSheet`. Lives in its own
/// resizable + movable NSWindow (unlike the previous `.sheet` flavour
/// that was glued to the parent window). Reads `hosts` from the shared
/// controller and writes install / file-drop intents back to it; the
/// owning `ContentView` reacts via `.onChange`.
struct PackagePickerWindow: View {
    @Environment(PackagePickerController.self) private var picker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PackagePickerSheet(
            hosts: picker.hosts,
            localTargetName: picker.localTarget?.name,
            onInstall: { pkg in
                openWindow(id: "main")
                picker.dismissPickerAfterPendingIntent = true
                picker.pendingDirectInstall = pkg
            },
            onInstallMunki: { pkg in
                openWindow(id: "main")
                picker.dismissPickerAfterPendingIntent = true
                picker.pendingMunkiInstall = pkg
            },
            onDropFile: { url in
                openWindow(id: "main")
                picker.dismissPickerAfterPendingIntent = true
                picker.pendingFileDrop = url
            }
        )
        .onAppear { activateAndFocus() }
        .onChange(of: picker.openCounter) { _, _ in
            // Re-presenting the same Window scene with new hosts: we
            // need to re-activate so the row click registers on first
            // press instead of the second (the first click was getting
            // eaten just bringing the app to the foreground).
            activateAndFocus()
        }
    }

    /// Force the app + this window to become key on the next runloop
    /// turn. Opening a SwiftUI Window scene from a non-key context can
    /// leave the window visible but inactive — clicking a row then
    /// only activates the window, requiring a second click to select.
    /// Activating explicitly avoids the dead first-click.
    private func activateAndFocus() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            // Look up the picker window by title and make it key. The
            // SwiftUI Window scene's title is set in BlueConnectApp.swift
            // ("Install Package…") and the AppKit-side NSWindow.title
            // mirrors that.
            if let w = NSApp.windows.first(where: {
                $0.title.hasPrefix("Install Package")
            }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
