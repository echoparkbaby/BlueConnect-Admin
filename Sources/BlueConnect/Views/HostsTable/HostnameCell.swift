import SwiftUI

struct HostnameCell: View {
    let host: BlueSkyHost
    let category: String?
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(host.displayName).bold()
            if let s = host.sharingname, !s.isEmpty, s != host.hostname {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
