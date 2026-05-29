import SwiftUI
import UniformTypeIdentifiers

/// Sheet that lets the user browse + filter the package catalog and pick
/// one to install on the targeted hosts. Triggered by right-click →
/// "Install Package…" or the Connect → Install Package… (⌘4) command.
///
/// Three sources are offered side-by-side via a segmented control at
/// the top: **Munki** = the Wasabi/S3 Munki repo, **Remote** = the JSON-
/// catalog HTTPS repo (`Settings → Package Repo → Repo URL`), and
/// **Local** = an ad-hoc `.pkg` / `.dmg` / `.app` the operator picks
/// from disk at run time. Local is always available; Munki and Remote
/// appear only when their respective settings are configured.
struct PackagePickerSheet: View {
    let hosts: [BlueSkyHost]
    /// Set when the picker is opened from a Local Network row instead of
    /// the BSC hosts list. `hosts` is empty in that case, but we still
    /// want the header to show the Mac's friendly name so the user can
    /// confirm they're aiming at the right thing.
    var localTargetName: String? = nil
    let onInstall: (Package) -> Void
    /// Called when the user picks a Munki package. Owner is responsible
    /// for fetching the installer via SigV4 and running it on `hosts`.
    let onInstallMunki: (MunkiPkg) -> Void
    /// Called when the user drops or picks a local .pkg / .dmg / .app file.
    /// Owner is responsible for: (1) installing it on `hosts`, (2) — if
    /// repo upload is configured — scp'ing it to the repo storage and
    /// refreshing the repo so it appears in the picker permanently.
    let onDropFile: (URL) -> Void

    @Environment(PackageCatalogStore.self) private var packageCatalog
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case munki, remote, local
        var id: String { rawValue }
        var label: String {
            switch self {
            case .munki:  return "Munki"
            case .remote: return "Remote"
            case .local:  return "Local"
            }
        }
    }

    @State private var source: Source = .munki
    @State private var query: String = ""
    @State private var selected: Package?
    @State private var selectedMunki: MunkiPkg.ID?
    @State private var pendingDestructive: Package?
    @State private var isDropping: Bool = false
    @State private var showingUploadPicker: Bool = false
    @State private var showingLocalFilePicker: Bool = false
    @State private var munkiStore = MunkiRepoStore()

    /// Shared with MunkiBrowserView — JSON `[String]` of package
    /// **names** (not name|version IDs) so a favorite tracks the
    /// newest version automatically.
    @AppStorage("munkiFavorites") private var munkiFavoritesRaw: String = "[]"

    /// Local is always available (no config needed — operator picks
    /// the file at run time), so the segmented control shows whenever
    /// at least one of the configurable sources is wired. The user's
    /// "Local" tab gives them a way to install ad-hoc files even when
    /// no repo is configured.
    private var availableSources: [Source] {
        var s: [Source] = []
        if settings.isMunkiRepoConfigured { s.append(.munki) }
        if !settings.packageCatalogURL.isEmpty { s.append(.remote) }
        s.append(.local)  // always
        return s
    }

    private var showSourcePicker: Bool { availableSources.count > 1 }

    private var sourcePicker: some View {
        HStack {
            Picker("Source", selection: $source) {
                ForEach(availableSources) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            if source == .munki {
                if munkiStore.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await munkiStore.refresh(settings: settings) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(munkiStore.isLoading)
                .help("Refresh Munki catalogs/all")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    /// Local-tab content: a big "Choose File…" button for picking a
    /// .pkg / .dmg / .app from disk, plus the same drag-and-drop
    /// instructions the rest of the window honors. Selection routes
    /// through the existing `onDropFile` callback so install +
    /// optional repo-upload run the same code path as a drag.
    private var localTab: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Install a local package")
                .font(.headline)
            Text("Pick a .pkg, .dmg, or .app from your Mac and install it on \(targetSummary). You can also drag a file anywhere onto this window.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Button {
                showingLocalFilePicker = true
            } label: {
                Label("Choose File…", systemImage: "doc.badge.arrow.up")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showingLocalFilePicker,
            allowedContentTypes: [.init(filenameExtension: "pkg") ?? .data,
                                  .init(filenameExtension: "dmg") ?? .data,
                                  .init(filenameExtension: "app") ?? .data,
                                  .application],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                onDropFile(url)
                dismiss()
            case .failure:
                break
            }
        }
    }

    private var allPackages: [Package] {
        packageCatalog.catalog?.packages ?? []
    }

    // MARK: - Munki source helpers

    /// Munki repos typically duplicate each pkginfo across catalog
    /// memberships (testing+production = 2 entries per pkginfo). Collapse
    /// to one row per `name`, keeping the newest version, and merging the
    /// catalogs lists so the UI still shows all catalogs the package
    /// belongs to. Sorted alphabetically by display name.
    private var groupedMunki: [MunkiPkg] {
        var byName: [String: MunkiPkg] = [:]
        for pkg in munkiStore.packages {
            if let existing = byName[pkg.name] {
                // Pick the newer version, but union the catalogs so the
                // detail pane still reports both testing/production etc.
                let mergedCatalogs = Array(Set(existing.catalogs).union(pkg.catalogs)).sorted()
                if Self.versionCompare(pkg.version, existing.version) == .orderedDescending {
                    byName[pkg.name] = pkg.withMergedCatalogs(mergedCatalogs)
                } else {
                    byName[pkg.name] = existing.withMergedCatalogs(mergedCatalogs)
                }
            } else {
                byName[pkg.name] = pkg
            }
        }
        return byName.values.sorted {
            $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName)
                == .orderedAscending
        }
    }

    /// Numeric-aware version compare. `NSString.compare(_:options:.numeric)`
    /// handles "1.10" > "1.9" and falls back to lex compare for non-numeric
    /// segments (alphas, betas, etc) — good enough for the Munki version
    /// strings we see in the wild.
    static func versionCompare(_ a: String, _ b: String) -> ComparisonResult {
        (a as NSString).compare(b, options: .numeric)
    }

    private var filteredMunki: [MunkiPkg] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = groupedMunki
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q)
                || $0.resolvedDisplayName.lowercased().contains(q)
                || ($0.description?.lowercased().contains(q) ?? false)
                || ($0.category?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedMunkiPkg: MunkiPkg? {
        guard let id = selectedMunki else { return nil }
        return groupedMunki.first { $0.id == id }
    }

    /// Total versions available for the currently-selected package name
    /// (across catalog memberships, deduped by version). Surfaced in the
    /// detail pane so users know there are older versions even though
    /// only the newest appears in the list.
    private var selectedVersionCount: Int {
        guard let sel = selectedMunkiPkg else { return 0 }
        let versions = Set(munkiStore.packages.filter { $0.name == sel.name }.map(\.version))
        return versions.count
    }

    private var filtered: [Package] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allPackages }
        return allPackages.filter {
            $0.name.lowercased().contains(q)
                || ($0.description ?? "").lowercased().contains(q)
                || ($0.group ?? "").lowercased().contains(q)
                || ($0.file ?? "").lowercased().contains(q)
        }
    }

    private var groupedFiltered: [(group: String, items: [Package])] {
        var seen: [String] = []
        var byGroup: [String: [Package]] = [:]
        for p in filtered {
            let g = p.group ?? ""
            if byGroup[g] == nil { seen.append(g) }
            byGroup[g, default: []].append(p)
        }
        return seen.map { ($0, byGroup[$0] ?? []) }
    }

    private var targetSummary: String {
        switch hosts.count {
        case 0: return localTargetName ?? "no host"
        case 1: return hosts[0].displayName
        default: return "\(hosts.count) hosts"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSourcePicker {
                Divider()
                sourcePicker
            }
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch source {
                    case .remote: list
                    case .munki:  munkiList
                    case .local:  localTab
                    }
                }
                .frame(maxWidth: .infinity)
                // Right-hand preview pane only applies to repo-backed
                // sources. Local-file picking has no preview state to
                // show — the file is selected and committed in one
                // gesture, so the divider + pane stay hidden.
                if source != .local {
                    Divider()
                    Group {
                        switch source {
                        case .remote: preview
                        case .munki:  munkiPreview
                        case .local:  EmptyView()
                        }
                    }
                    .frame(width: 260)
                }
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .task {
            if settings.isMunkiRepoConfigured && munkiStore.packages.isEmpty
                && munkiStore.lastError == nil {
                await munkiStore.refresh(settings: settings)
            }
            // Default to whichever source actually has content. Munki
            // first (per user request), then Remote when only it is
            // configured, then Local as the catch-all.
            if !availableSources.contains(source) {
                source = availableSources.first ?? .local
            }
            if source == .munki && !settings.isMunkiRepoConfigured {
                source = !allPackages.isEmpty ? .remote : .local
            }
        }
        .overlay {
            if isDropping {
                ZStack {
                    Color.accentColor.opacity(0.18)
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox.and.arrow.backward")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Drop .pkg / .dmg / .app to install on \(targetSummary)")
                            .font(.headline)
                        Text("If a Repo upload path is configured, the file will also be added to the repo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            let ext = url.pathExtension.lowercased()
            guard ext == "pkg" || ext == "dmg" || ext == "app" else { return false }
            onDropFile(url)
            dismiss()
            return true
        } isTargeted: { hovering in
            isDropping = hovering
        }
        .alert("Run \(pendingDestructive?.name ?? "package")?",
               isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
               ),
               presenting: pendingDestructive) { pkg in
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
            Button("Run on \(targetSummary)", role: .destructive) {
                commit(pkg)
            }
        } message: { pkg in
            let desc = pkg.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Text(desc.isEmpty
                 ? "This will run an uninstall or destructive command on \(targetSummary). Continue?"
                 : desc)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Install Package").font(.headline)
                Text("Run on \(targetSummary)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Upload-to-repo is a Direct-repo concept (SCP/FTP/Nextcloud
            // PUT into the catalog server). Munki repos are populated via
            // `makecatalogs` from outside the app, so hide the button when
            // the Munki tab is active to avoid implying it works there.
            if source == .remote {
                Button {
                    showingUploadPicker = true
                } label: {
                    Label("Upload to Repo…", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .help("Pick a local .pkg / .dmg / .app to install and add to the repo. Or drop one anywhere in this window.")
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .fileImporter(isPresented: $showingUploadPicker,
                      allowedContentTypes: [
                        UTType(filenameExtension: "pkg") ?? .data,
                        UTType(filenameExtension: "dmg") ?? .data,
                        .application,
                      ]) { result in
            if case .success(let url) = result {
                onDropFile(url)
                dismiss()
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, group, or file", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if filtered.isEmpty {
                        Text(allPackages.isEmpty
                             ? "No catalog loaded. Add a Catalog URL in Settings → Packages."
                             : "No packages match “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(24)
                    } else {
                        ForEach(Array(groupedFiltered.enumerated()), id: \.offset) { _, section in
                            Section {
                                ForEach(section.items) { pkg in
                                    packageRow(pkg)
                                }
                            } header: {
                                if !section.group.isEmpty {
                                    Text(section.group.uppercased())
                                        .font(.caption2).bold().foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14).padding(.vertical, 4)
                                        .background(Color(NSColor.controlBackgroundColor))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let pkg = selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: pkg.resolvedIcon)
                        .font(.system(size: 32))
                        .foregroundStyle(pkg.isDestructive ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pkg.name).font(.headline).lineLimit(2)
                        if let g = pkg.group, !g.isEmpty {
                            Text(g.uppercased())
                                .font(.caption2).bold().foregroundStyle(.secondary)
                        }
                    }
                }
                if pkg.isDestructive {
                    Label("Destructive — will prompt before running", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Divider()
                if let d = pkg.description, !d.isEmpty {
                    Text("Notes").font(.caption).bold().foregroundStyle(.secondary)
                    Text(d).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No notes for this package.")
                        .font(.callout).foregroundStyle(.secondary).italic()
                    Text("Add a `description` for `\(pkg.file ?? pkg.name)` in your repo's metadata.json.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Details").font(.caption).bold().foregroundStyle(.secondary)
                    if let f = pkg.file {
                        detailRow("File", value: f, mono: true)
                    }
                    if pkg.command != nil {
                        detailRow("Type", value: "Shell command")
                    } else if let f = pkg.file {
                        detailRow("Type", value: f.lowercased().hasSuffix(".dmg") ? "Disk Image" : "Installer Package")
                    }
                    if let v = pkg.version {
                        detailRow("Version", value: pkg.buildNumber.map { "\(v) (\($0))" } ?? v, mono: true)
                    }
                    if let id = pkg.bundleID { detailRow("Bundle", value: id, mono: true) }
                    if let m = pkg.minSystem { detailRow("Min", value: "macOS \(m)+") }
                    if let g = pkg.group { detailRow("Group", value: g.isEmpty ? "—" : g) }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a package to see its notes")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Drop a .pkg / .dmg / .app anywhere in this window to install + add to your repo.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var munkiList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter Munki packages", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let err = munkiStore.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Button("Retry") { Task { await munkiStore.refresh(settings: settings) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !settings.isMunkiRepoConfigured {
                VStack(spacing: 6) {
                    Text("Munki Repo not configured")
                        .font(.headline).foregroundStyle(.secondary)
                    Text("Add endpoint + credentials in Settings → Munki Repo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredMunki.isEmpty {
                Text(munkiStore.packages.isEmpty
                     ? "No catalog loaded yet."
                     : "No packages match “\(query)”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24)
            } else {
                // Sectioned list — favorites at the top so the
                // operator's "I install this all the time" packages
                // are always in reach. Reads the same @AppStorage
                // key MunkiBrowserView writes.
                let favs = MunkiFavorites.decode(munkiFavoritesRaw)
                let favoriteRows = filteredMunki.filter { favs.contains($0.name) }
                let otherRows    = filteredMunki.filter { !favs.contains($0.name) }
                // No `.simultaneousGesture(TapGesture(count: 2))` on
                // these rows. It races with List's built-in
                // tap-to-select on macOS and was eating single clicks
                // (3–4 click selection). The footer Install button is
                // the explicit commit path; double-click-to-install
                // is not worth a broken selection click.
                List(selection: $selectedMunki) {
                    if !favoriteRows.isEmpty {
                        Section("Favorites") {
                            ForEach(favoriteRows) { pkg in
                                munkiRow(pkg, isFavorite: true)
                                    .tag(pkg.id)
                                    .contextMenu { munkiVersionsMenu(for: pkg) }
                            }
                        }
                    }
                    Section(favoriteRows.isEmpty ? "" : "All packages") {
                        ForEach(otherRows) { pkg in
                            munkiRow(pkg, isFavorite: false)
                                .tag(pkg.id)
                                .contextMenu { munkiVersionsMenu(for: pkg) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// Versions context-menu builder. The picker collapses to one row per
    /// `name`; right-click drops the user into the full version history so
    /// they can deploy a pinned older build instead of the latest.
    @ViewBuilder
    private func munkiVersionsMenu(for pkg: MunkiPkg) -> some View {
        let versions = allVersions(of: pkg.name)
        Button("Install latest (\(pkg.version))") {
            onInstallMunki(pkg)
            dismiss()
        }
        if versions.count > 1 {
            Menu("Install Specific Version") {
                ForEach(versions, id: \.id) { v in
                    Button(v.version == pkg.version
                           ? "\(v.version) — latest"
                           : v.version) {
                        onInstallMunki(v)
                        dismiss()
                    }
                }
            }
        }
        Divider()
        let favs = MunkiFavorites.decode(munkiFavoritesRaw)
        let isFav = favs.contains(pkg.name)
        Button(isFav ? "Unfavorite \(pkg.resolvedDisplayName)"
                     : "Favorite \(pkg.resolvedDisplayName)") {
            munkiFavoritesRaw = MunkiFavorites.toggling(pkg.name, in: munkiFavoritesRaw)
        }
        Button("Show in detail pane") {
            selectedMunki = pkg.id
        }
    }

    /// Every pkginfo entry for a given name, deduped by version, sorted
    /// newest → oldest (so the menu reads top-down latest-to-oldest).
    private func allVersions(of name: String) -> [MunkiPkg] {
        var seen = Set<String>()
        var rows: [MunkiPkg] = []
        for p in munkiStore.packages where p.name == name {
            guard !seen.contains(p.version) else { continue }
            seen.insert(p.version)
            rows.append(p)
        }
        return rows.sorted {
            Self.versionCompare($0.version, $1.version) == .orderedDescending
        }
    }

    private func munkiRow(_ pkg: MunkiPkg, isFavorite: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Star toggle — favorites a NAME, so the pinned row
            // always tracks whatever version is newest in the repo.
            Button {
                munkiFavoritesRaw = MunkiFavorites.toggling(pkg.name, in: munkiFavoritesRaw)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary.opacity(0.5))
                    .font(.caption)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unfavorite \(pkg.resolvedDisplayName)" : "Favorite \(pkg.resolvedDisplayName)")

            Image(systemName: "cube.box")
                .font(.body).foregroundStyle(.blue).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(pkg.resolvedDisplayName).font(.callout)
                    Text(pkg.version).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let d = pkg.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Text(pkg.archSummary)
                            .font(.caption2).foregroundStyle(.secondary)
                        if !pkg.catalogs.isEmpty {
                            Text("· \(pkg.catalogs.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // contentShape makes the entire HStack — including the
        // Spacer's empty area — hit-test as one rectangle so List's
        // selection picks up clicks anywhere on the row.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var munkiPreview: some View {
        if let pkg = selectedMunkiPkg {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.box.fill")
                            .font(.system(size: 32)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pkg.resolvedDisplayName).font(.headline).lineLimit(2)
                            Text(pkg.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if let d = pkg.description, !d.isEmpty {
                        Text("Notes").font(.caption).bold().foregroundStyle(.secondary)
                        Text(d).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Details").font(.caption).bold().foregroundStyle(.secondary)
                        detailRow("Version", value: pkg.version, mono: true)
                        if selectedVersionCount > 1 {
                            detailRow("Available",
                                      value: "\(selectedVersionCount) versions in repo")
                        }
                        detailRow("Size", value: pkg.humanSize)
                        detailRow("Archs", value: pkg.archSummary)
                        if let min = pkg.minimumOSVersion {
                            detailRow("Min", value: "macOS \(min)+")
                        }
                        if let dev = pkg.developer { detailRow("Dev", value: dev) }
                        if let cat = pkg.category { detailRow("Cat", value: cat) }
                        if !pkg.catalogs.isEmpty {
                            detailRow("Catalogs", value: pkg.catalogs.joined(separator: ", "))
                        }
                        if let loc = pkg.installerItemLocation {
                            detailRow("Path", value: loc, mono: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cube.box")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Select a Munki package")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailRow(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func packageRow(_ pkg: Package) -> some View {
        let isSelected = selected == pkg
        return Button {
            selected = pkg
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: pkg.resolvedIcon)
                    .font(.body)
                    .foregroundStyle(pkg.isDestructive ? Color.orange : Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pkg.name).font(.callout)
                    if let d = pkg.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if let f = pkg.file {
                        Text(f).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    } else if pkg.command != nil {
                        Text("Shell command").font(.caption).foregroundStyle(.secondary).italic()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Rectangle().fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { runSelected() })
    }

    private var footer: some View {
        HStack {
            switch source {
            case .remote:
                if let sel = selected {
                    HStack(spacing: 4) {
                        Image(systemName: sel.resolvedIcon)
                            .foregroundStyle(sel.isDestructive ? Color.orange : Color.accentColor)
                        Text(sel.name).font(.callout).bold().lineLimit(1)
                    }
                } else {
                    Text("Pick a package").font(.callout).foregroundStyle(.secondary)
                }
            case .munki:
                if let sel = selectedMunkiPkg {
                    HStack(spacing: 4) {
                        Image(systemName: "cube.box").foregroundStyle(.blue)
                        Text(sel.resolvedDisplayName).font(.callout).bold().lineLimit(1)
                        Text(sel.version).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Pick a Munki package").font(.callout).foregroundStyle(.secondary)
                }
            case .local:
                // Local has no selection state — file picking IS the
                // install commit. Footer shows a hint instead of a
                // selected-name preview.
                Text("Use Choose File… above").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            // Hide the prominent install button entirely on Local —
            // there's nothing to install until the file picker
            // returns, and once it does the sheet auto-commits +
            // dismisses, so a button here would never fire.
            if source != .local {
                Button {
                    switch source {
                    case .remote: runSelected()
                    case .munki:  runSelectedMunki()
                    case .local:  break  // unreachable, guarded above
                    }
                } label: {
                    Text(installButtonLabel)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRunSelection || !hasInstallTarget)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var installButtonLabel: String {
        switch source {
        case .remote:
            return selected?.isDestructive == true
                ? "Run on \(targetSummary)"
                : "Install on \(targetSummary)"
        case .munki:
            return "Install on \(targetSummary)"
        case .local:
            return ""  // button is hidden on Local; this is a fallback
        }
    }

    private var canRunSelection: Bool {
        switch source {
        case .remote: return selected != nil
        case .munki:  return selectedMunki != nil
        case .local:  return false  // file picker handles its own commit
        }
    }

    /// True when there's somewhere to send the install — a non-empty BSC
    /// host list, OR a Local Network localTarget. Without this the LAN
    /// install path is dead because `hosts` is intentionally empty when
    /// LocalNetworkRow opens the picker.
    private var hasInstallTarget: Bool {
        !hosts.isEmpty || localTargetName != nil
    }

    private func runSelected() {
        guard let pkg = selected, hasInstallTarget else { return }
        if pkg.isDestructive {
            pendingDestructive = pkg
        } else {
            commit(pkg)
        }
    }

    private func runSelectedMunki() {
        guard let pkg = selectedMunkiPkg, hasInstallTarget else { return }
        onInstallMunki(pkg)
        dismiss()
    }

    private func commit(_ pkg: Package) {
        onInstall(pkg)
        pendingDestructive = nil
        dismiss()
    }
}
