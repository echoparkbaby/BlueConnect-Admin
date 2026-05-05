import AppKit
import SwiftUI

struct LogPaneView: View {
    private var log = RuntimeLog.shared
    @State private var filterLevel: LevelFilter = .all
    @State private var search: String = ""

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, info, warn, error
        var id: String { rawValue }
    }

    private var filtered: [RuntimeLogEntry] {
        log.entries.filter { e in
            (filterLevel == .all || e.level.rawValue == filterLevel.rawValue) &&
            (search.isEmpty
                || e.message.localizedStandardContains(search)
                || e.category.localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $filterLevel) {
                    ForEach(LevelFilter.allCases) { f in
                        Text(f.rawValue.capitalized).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                TextField("Filter…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.formattedDump(), forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy entire log to clipboard")
                Button(role: .destructive) { log.clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("No log entries match", systemImage: "text.alignleft")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { e in
                            LogRow(entry: e)
                            Divider().opacity(0.25)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
}
