import SwiftUI

/// Browse-and-install view of a Munki repo's `catalogs/all`. Opens from
/// the sidebar, the Connection menu, or Settings. Right-click a row to
/// drill into older versions; the Install button at the bottom-right
/// presents a host picker so you can deploy to one or many machines
/// without backing out to the host list.
struct MunkiBrowserView: View {
    /// Shared store — keeps the sidebar count, the picker, and this
    /// browser in sync without re-fetching catalogs/all per surface.
    let store: MunkiRepoStore

    @EnvironmentObject private var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(PackagePickerController.self) private var packagePicker
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var catalogFilter: String = "all"
    @State private var selection: MunkiPkg.ID?
    /// Persisted list of favorited package NAMES (not versions) —
    /// "Firefox" stays favorited as the Munki repo cuts new versions;
    /// each render resolves the name to the newest available version
    /// via `groupedPackages`. Stored as JSON-encoded `[String]` in
    /// UserDefaults so the picker's Munki tab can read the same key
    /// and stay in sync without an extra store.
    @AppStorage("munkiFavorites") private var favoritesRaw: String = "[]"

    /// Set when the user clicks Install (or picks a specific version
    /// from the right-click menu). Drives presentation of the host
    /// picker sheet.
    @State private var pendingInstall: MunkiPkg?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
        .task {
            // Cache populates packages instantly; refresh runs only if
            // cache is stale, so opening the browser is near-zero-cost
            // when you've used it recently.
            store.loadFromCacheIfPresent(settings: settings)
            await store.refresh(settings: settings)
        }
        .sheet(item: $pendingInstall) { pkg in
            MunkiHostPickerSheet(pkg: pkg) { picked in
                packagePicker.hosts = picked
                packagePicker.pendingMunkiInstall = pkg
                pendingInstall = nil
                dismiss()
            }
            .environment(hostStore)
        }
    }

    // MARK: - Header / toolbar / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.box.fill")
                .font(.title3).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Munki Repo").font(.headline)
                Text(endpointSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Button {
                Task { await store.refresh(force: true, settings: settings) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var endpointSubtitle: String {
        let host = settings.munkiRepoEndpoint.isEmpty
            ? "(no endpoint set)" : settings.munkiRepoEndpoint
        let bucket = settings.munkiRepoBucket.isEmpty
            ? "" : " / \(settings.munkiRepoBucket)"
        let region = settings.munkiRepoAuthMode == "basic" || settings.munkiRepoAuthMode == "none"
            ? "" : " · \(settings.munkiRepoRegion)"
        return host + bucket + region
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search packages…", text: $search)
                .textFieldStyle(.plain)
            Picker("Catalog", selection: $catalogFilter) {
                Text("All catalogs").tag("all")
                ForEach(availableCatalogs, id: \.self) { c in
                    Text(c).tag(c)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text("\(filteredPackages.count)/\(uniqueNamesCount)")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if let when = store.lastFetched {
                Text("Last refreshed \(when, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                if let pkg = selectedPkg { pendingInstall = pkg }
            } label: {
                Text("Install…")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedPkg == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = store.lastError, store.packages.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text(err)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .font(.callout)
                Button("Retry") {
                    Task { await store.refresh(force: true, settings: settings) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.packages.isEmpty && !store.isLoading {
            VStack(spacing: 12) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text("No packages loaded yet").foregroundStyle(.secondary)
                Button("Load catalogs/all") {
                    Task { await store.refresh(force: true, settings: settings) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                packageList
                    .frame(minWidth: 280, idealWidth: 320)
                detailPane
                    .frame(minWidth: 320)
            }
        }
    }

    private var packageList: some View {
        // Capture the decoded set in the body context so SwiftUI tracks
        // the @AppStorage("munkiFavorites") dependency and re-renders
        // when the user toggles a star. `groupedPackages` already
        // resolves each name to the newest version — favoriting
        // "Firefox" gets the current newest Firefox each time.
        let favs = MunkiFavorites.decode(favoritesRaw)
        let favoritePkgs = filteredPackages.filter { favs.contains($0.name) }
        let otherPkgs    = filteredPackages.filter { !favs.contains($0.name) }
        return List(selection: $selection) {
            if !favoritePkgs.isEmpty {
                Section("Favorites") {
                    ForEach(favoritePkgs) { pkg in
                        row(for: pkg, isFavorite: true)
                            .tag(pkg.id)
                            .contextMenu { versionsMenu(for: pkg) }
                    }
                }
            }
            Section(favoritePkgs.isEmpty ? "" : "All packages") {
                ForEach(otherPkgs) { pkg in
                    row(for: pkg, isFavorite: false)
                        .tag(pkg.id)
                        .contextMenu { versionsMenu(for: pkg) }
                }
            }
        }
        .listStyle(.inset)
        // Double-click a selection to install — handled via onChange of the
        // List's tap count is not possible, but tapping a row sets
        // `selection`; if the user wants install, they use the context menu
        // or the footer Install button. The previous .simultaneousGesture
        // for double-click was racing with List's own click-to-select on
        // macOS, making single-click selection unresponsive.
    }

    private func row(for pkg: MunkiPkg, isFavorite: Bool) -> some View {
        HStack(spacing: 8) {
            // Star toggle — favorites a NAME not a version, so the
            // pinned row tracks the newest version automatically.
            Button {
                favoritesRaw = MunkiFavorites.toggling(pkg.name, in: favoritesRaw)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary.opacity(0.5))
                    .font(.caption)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unfavorite \(pkg.resolvedDisplayName)" : "Favorite \(pkg.resolvedDisplayName)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pkg.resolvedDisplayName).font(.body)
                    Text(pkg.version)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                HStack(spacing: 6) {
                    if !pkg.catalogs.isEmpty {
                        Text(pkg.catalogs.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func versionsMenu(for pkg: MunkiPkg) -> some View {
        let versions = allVersions(of: pkg.name)
        Button("Install latest (\(pkg.version))…") {
            presentInstall(pkg)
        }
        if versions.count > 1 {
            Menu("Install Specific Version…") {
                ForEach(versions, id: \.id) { v in
                    Button(v.version == pkg.version
                           ? "\(v.version) — latest"
                           : v.version) {
                        presentInstall(v)
                    }
                }
            }
        }
        Divider()
        let favs = MunkiFavorites.decode(favoritesRaw)
        let isFav = favs.contains(pkg.name)
        Button(isFav ? "Unfavorite \(pkg.resolvedDisplayName)"
                     : "Favorite \(pkg.resolvedDisplayName)") {
            favoritesRaw = MunkiFavorites.toggling(pkg.name, in: favoritesRaw)
        }
        Button("Select") { selection = pkg.id }
    }

    /// Defers the `pendingInstall` write one runloop tick. Setting a
    /// `.sheet(item:)` binding directly inside a contextMenu's action
    /// races with the menu's own dismissal animation on macOS — the
    /// state mutation gets clobbered and the sheet never presents. The
    /// async hop ensures the menu is fully torn down first.
    private func presentInstall(_ pkg: MunkiPkg) {
        Task { @MainActor in
            pendingInstall = pkg
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let pkg = selectedPkg {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(pkg.resolvedDisplayName).font(.title3).bold()
                    if pkg.resolvedDisplayName != pkg.name {
                        Text(pkg.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        detailRow("Version", pkg.version)
                        if allVersions(of: pkg.name).count > 1 {
                            detailRow("Available",
                                      "\(allVersions(of: pkg.name).count) versions (right-click to pick)")
                        }
                        detailRow("Size", pkg.humanSize)
                        detailRow("Architectures", pkg.archSummary)
                        if let min = pkg.minimumOSVersion { detailRow("Min macOS", min) }
                        if let dev = pkg.developer { detailRow("Developer", dev) }
                        if let cat = pkg.category { detailRow("Category", cat) }
                        if !pkg.catalogs.isEmpty {
                            detailRow("Catalogs", pkg.catalogs.joined(separator: ", "))
                        }
                        if let loc = pkg.installerItemLocation {
                            detailRow("Location", loc)
                        }
                    }
                    if let desc = pkg.description, !desc.isEmpty {
                        Divider()
                        Text("Description").font(.caption).bold().foregroundStyle(.secondary)
                        Text(desc).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a package")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Filtering / grouping

    /// One row per unique package name (newest version), matching the
    /// picker's grouping. Removes catalog-membership duplicates.
    private var groupedPackages: [MunkiPkg] {
        var byName: [String: MunkiPkg] = [:]
        for pkg in store.packages {
            if let existing = byName[pkg.name] {
                let merged = Array(Set(existing.catalogs).union(pkg.catalogs)).sorted()
                if (pkg.version as NSString).compare(existing.version, options: .numeric)
                    == .orderedDescending {
                    byName[pkg.name] = pkg.withMergedCatalogs(merged)
                } else {
                    byName[pkg.name] = existing.withMergedCatalogs(merged)
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

    private var filteredPackages: [MunkiPkg] {
        var pkgs = groupedPackages
        if catalogFilter != "all" {
            pkgs = pkgs.filter { $0.catalogs.contains(catalogFilter) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            pkgs = pkgs.filter {
                $0.name.lowercased().contains(q)
                || $0.resolvedDisplayName.lowercased().contains(q)
                || ($0.description?.lowercased().contains(q) ?? false)
                || ($0.category?.lowercased().contains(q) ?? false)
            }
        }
        return pkgs
    }

    private var availableCatalogs: [String] {
        Array(Set(store.packages.flatMap(\.catalogs))).sorted()
    }

    private var uniqueNamesCount: Int {
        Set(store.packages.map(\.name)).count
    }

    private var selectedPkg: MunkiPkg? {
        guard let id = selection else { return nil }
        return groupedPackages.first { $0.id == id }
    }

    /// Every version of a given package name, newest first.
    private func allVersions(of name: String) -> [MunkiPkg] {
        var seen = Set<String>()
        var rows: [MunkiPkg] = []
        for p in store.packages where p.name == name {
            guard !seen.contains(p.version) else { continue }
            seen.insert(p.version)
            rows.append(p)
        }
        return rows.sorted {
            ($0.version as NSString).compare($1.version, options: .numeric)
                == .orderedDescending
        }
    }
}

/// Post-Install sheet — pick which host(s) get the package. Defaults to
/// active hosts, multi-select. Filter box at top handles big fleets.
struct MunkiHostPickerSheet: View {
    let pkg: MunkiPkg
    let onConfirm: ([BlueSkyHost]) -> Void

    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var selectedIDs: Set<BlueSkyHost.ID> = []

    private var activeHosts: [BlueSkyHost] {
        hostStore.hosts.filter { $0.active }
    }

    private var filteredHosts: [BlueSkyHost] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return activeHosts }
        return activeHosts.filter {
            $0.displayName.lowercased().contains(q)
                || ($0.serialnum ?? "").lowercased().contains(q)
                || ($0.username ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cube.box.fill")
                    .font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Install \(pkg.resolvedDisplayName) \(pkg.version)")
                        .font(.headline)
                    Text("Pick host(s) to deploy to")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search hosts…", text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            Divider()
            List(filteredHosts, selection: $selectedIDs) { h in
                hostRow(h)
                    .tag(h.id)
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Select All") {
                    selectedIDs = Set(filteredHosts.map(\.id))
                }
                Button("Clear") { selectedIDs.removeAll() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let picked = activeHosts.filter { selectedIDs.contains($0.id) }
                    onConfirm(picked)
                } label: {
                    Text(selectedIDs.count > 1
                         ? "Install on \(selectedIDs.count) Hosts"
                         : "Install")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 540, height: 460)
    }

    private func hostRow(_ h: BlueSkyHost) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(h.active ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.displayName).font(.body)
                HStack(spacing: 6) {
                    if let u = h.username, !u.isEmpty {
                        Text(u).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let s = h.serialnum, !s.isEmpty {
                        Text(s).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
    }
}
