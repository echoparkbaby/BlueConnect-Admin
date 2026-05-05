import SwiftUI

struct RenameSheet: View {
    let host: BlueSkyHost
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String

    init(host: BlueSkyHost, onSave: @escaping (String) -> Void) {
        self.host = host
        self.onSave = onSave
        self._newName = State(initialValue: host.hostname ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename #\(host.blueskyid)").font(.headline)
            Text("Updates the `hostname` field on the BlueSky DB row. Visible to all operators.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Hostname", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func save() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
