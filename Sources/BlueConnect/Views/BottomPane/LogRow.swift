import SwiftUI

struct LogRow: View {
    let entry: RuntimeLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .frame(width: 48, alignment: .leading)
            Text(entry.category)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tint)
                .frame(width: 80, alignment: .leading)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
    }
}
