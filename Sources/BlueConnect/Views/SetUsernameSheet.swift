import SwiftUI

struct SetUsernameSheet: View {
    let hosts: [BlueSkyHost]
    let currentDefault: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newUser: String

    init(hosts: [BlueSkyHost], currentDefault: String, onSave: @escaping (String) -> Void) {
        self.hosts = hosts
        self.currentDefault = currentDefault
        self.onSave = onSave
        // Pre-fill only when every selected host already shares one value;
        // otherwise start blank so a mass-edit doesn't silently overwrite
        // distinct per-host values with whichever happened to come first.
        let uniq = Set(hosts.map { $0.username ?? "" })
        self._newUser = State(initialValue: uniq.count == 1 ? (uniq.first ?? "") : "")
    }

    private var titleText: String {
        if hosts.count == 1, let h = hosts.first {
            return "Set Username for #\(h.blueskyid)"
        }
        return "Set Username for \(hosts.count) Hosts"
    }

    private var bodyText: String {
        if hosts.count == 1 {
            return "Updates the `username` field on the BlueSky DB row. Used as the SSH/VNC/SCP user for this host on every operator's BlueConnect Admin. Leave blank to fall back to Settings → Connection defaults → Default remote user."
        }
        return "Updates the `username` field on \(hosts.count) BlueSky DB rows. Used as the SSH/VNC/SCP user for each host on every operator's BlueConnect Admin. Leave blank to clear all overrides and fall back to Settings → Connection defaults → Default remote user."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleText).font(.headline)
            Text(bodyText)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hosts.count > 1 {
                let uniq = Set(hosts.map { $0.username ?? "" })
                if uniq.count > 1 {
                    Text("Selected hosts currently have **\(uniq.count) different** username values — saving will overwrite all of them.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            TextField("Remote username", text: $newUser, prompt: Text(verbatim: currentDefault.isEmpty ? "admin" : currentDefault))
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if newUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(currentDefault.isEmpty
                     ? "No default set — leaving this blank will block SSH until a default is configured."
                     : "Will fall back to the global default: \(currentDefault)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hosts.count > 1 ? "Save for \(hosts.count) Hosts" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    private func save() {
        onSave(newUser.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
