import SwiftUI

struct UserCell: View {
    let host: BlueSkyHost
    let defaultUser: String

    var body: some View {
        let eff = host.effectiveUser(default: defaultUser)
        HStack(spacing: 4) {
            Text(eff)
            if (host.username ?? "").isEmpty {
                Text("(default)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
