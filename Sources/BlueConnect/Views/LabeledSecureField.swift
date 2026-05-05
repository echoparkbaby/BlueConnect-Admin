import SwiftUI

struct LabeledSecureField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
