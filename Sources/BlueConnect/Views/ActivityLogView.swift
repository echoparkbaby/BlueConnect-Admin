import SwiftUI

struct ActivityLogView: View {
    @Environment(ActivityLog.self) var log
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log").font(.headline)
                Spacer()
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if log.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No activity yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(log.entries) { e in
                            row(e)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func row(_ e: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.kind.rawValue)
                .foregroundStyle(e.kind.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(e.title).bold()
                    Spacer()
                    Text(e.timestamp, style: .time)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let d = e.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
