import SwiftUI

struct CategorySheet: View {
    let hosts: [BlueSkyHost]
    var categories: CategoryStore
    let onAssign: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newCategory: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headline).font(.headline)
            Text("Categories sync across operators (stored on the BlueSky server).")
                .font(.caption).foregroundStyle(.secondary)

            if !categories.categories.isEmpty {
                Text("Existing").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(categories.categories, id: \.self) { c in
                            Button {
                                onAssign(c); dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "tag")
                                    Text(c)
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(.rect(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 200)
                Divider()
            }

            Text("Or new category").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. Production, Family, Beta", text: $newCategory)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveNew() }

            HStack {
                Button(role: .destructive) {
                    onAssign(nil); dismiss()
                } label: { Text("Clear") }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { saveNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var headline: String {
        if hosts.count == 1, let h = hosts.first {
            return "Set Category for #\(h.blueskyid)"
        }
        return "Set Category for \(hosts.count) Hosts"
    }

    private func saveNew() {
        let t = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAssign(t); dismiss()
    }
}
