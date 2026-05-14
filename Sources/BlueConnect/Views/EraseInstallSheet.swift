import SwiftUI

/// Modal sheet for running Graham Pugh's `erase-install.sh` on a single
/// host. Exposes the parameters BlueConnect Admins care about (mode,
/// macOS version, power / safety, reboot, erase-mode tweaks, host UI,
/// download method, lifecycle, scripting hooks). Free-form "extra flags"
/// catches anything we don't surface.
///
/// Defaults reflect the user's typical set:
///   --check-power · --power-wait-limit 180
///   --min-drive-space=50 · --cleanup-after-use
///
/// Wiki reference: https://github.com/grahampugh/erase-install/wiki
struct EraseInstallSheet: View {
    let host: BlueSkyHost
    let onRun: (RunSpec) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // MARK: - Spec passed back to the caller

    struct RunSpec: Codable, Hashable {
        var mode: Mode
        var versionPicker: VersionPicker
        var versionText: String
        var includeBetas: Bool
        var letUserSelectOnHost: Bool
        var checkPower: Bool
        var powerWaitLimit: String
        var minBattery: String
        var checkFMM: Bool
        var fmmWaitLimit: String
        var minDriveSpace: String
        var rebootDelay: String
        var newVolumeName: String
        var preserveContainer: Bool
        var noFullscreen: Bool
        var showConfirmOnHost: Bool
        var downloadMethod: DownloadMethod
        var cachingServer: String
        var cleanupAfterUse: Bool
        var overwriteInstaller: Bool
        var updateIfStale: Bool
        var replaceIfInvalid: Bool
        var preinstallCommand: String
        var postinstallCommand: String
        var extraFlags: String
    }

    /// One persisted past run, used to pre-fill the form.
    struct RecentRun: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var timestamp: Date
        var hostName: String
        var spec: RunSpec
        var isFavorite: Bool = false
        /// User-facing label e.g. "reinstall on pine · 14m ago".
        /// Favorites get a leading star so they're scannable in the menu.
        var menuLabel: String {
            let ago = RelativeDateTimeFormatter()
            ago.unitsStyle = .abbreviated
            let star = isFavorite ? "★ " : ""
            return "\(star)\(spec.mode.label) on \(hostName) · \(ago.localizedString(for: timestamp, relativeTo: Date()))"
        }
    }

    enum Mode: String, CaseIterable, Identifiable, Codable {
        case reinstall, erase, list, testRun
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reinstall: return "Reinstall (keep data)"
            case .erase:     return "Erase + Reinstall (factory)"
            case .list:      return "List available installers (no action)"
            case .testRun:   return "Test run (dry, no install)"
            }
        }
        var flag: String {
            switch self {
            case .reinstall: return "--reinstall"
            case .erase:     return "--erase"
            case .list:      return "--list"
            case .testRun:   return "--test-run"
            }
        }
        var isDestructive: Bool { self == .erase }
    }

    enum VersionPicker: String, CaseIterable, Identifiable, Codable {
        case latest, sameOS, sameBuild, majorOS, specificVersion, specificBuild
        var id: String { rawValue }
        var label: String {
            switch self {
            case .latest:           return "Latest available"
            case .sameOS:           return "Same major version as current"
            case .sameBuild:        return "Same build as current"
            case .majorOS:          return "Specific major version"
            case .specificVersion:  return "Specific minor version (NN.Y.Z)"
            case .specificBuild:    return "Specific build (XYZ)"
            }
        }
        var needsValue: Bool {
            self == .majorOS || self == .specificVersion || self == .specificBuild
        }
    }

    enum DownloadMethod: String, CaseIterable, Identifiable, Codable {
        case native, mist, ffi
        var id: String { rawValue }
        var label: String {
            switch self {
            case .native: return "Native (default)"
            case .mist:   return "mist-cli"
            case .ffi:    return "softwareupdate --fetch-full-installer"
            }
        }
        var flag: String {
            switch self {
            case .native: return "--native"
            case .mist:   return "--mist"
            case .ffi:    return "--fetch-full-installer"
            }
        }
    }

    // MARK: - State (sensible defaults for the user's typical fleet)

    @State private var mode: Mode = .reinstall
    @State private var versionPicker: VersionPicker = .latest
    @State private var versionText: String = ""
    @State private var includeBetas: Bool = false
    @State private var letUserSelectOnHost: Bool = false

    @State private var checkPower: Bool = true
    @State private var powerWaitLimit: String = "180"
    @State private var minBattery: String = ""
    @State private var checkFMM: Bool = true
    @State private var fmmWaitLimit: String = "300"
    @State private var minDriveSpace: String = "50"

    @State private var rebootDelay: String = "60"
    @State private var newVolumeName: String = ""
    @State private var preserveContainer: Bool = false

    @State private var noFullscreen: Bool = false
    @State private var showConfirmOnHost: Bool = false

    @State private var downloadMethod: DownloadMethod = .native
    @State private var cachingServer: String = ""

    @State private var cleanupAfterUse: Bool = true
    @State private var overwriteInstaller: Bool = false
    @State private var updateIfStale: Bool = false
    @State private var replaceIfInvalid: Bool = false

    @State private var preinstallCommand: String = ""
    @State private var postinstallCommand: String = ""
    @State private var extraFlags: String = ""

    @State private var hostnameConfirm: String = ""

    private var hostnameTarget: String { host.displayName }

    private var requiresHostnameConfirm: Bool {
        mode.isDestructive
    }

    private var canRun: Bool {
        guard !requiresHostnameConfirm else {
            return hostnameConfirm.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(hostnameTarget, options: .caseInsensitive) == .orderedSame
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            recentRunsBar
            Divider()
            ScrollView { form }
            Divider()
            commandPreview
            Divider()
            footer
        }
        .frame(width: 520, height: 700)
    }

    @ViewBuilder
    private var recentRunsBar: some View {
        let recent = sortedRecentRuns()
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Recent runs").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if recent.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                Menu {
                    Section("Apply") {
                        ForEach(recent) { run in
                            Button(run.menuLabel) { applyRecent(run) }
                        }
                    }
                    Section("Toggle favorite") {
                        ForEach(recent) { run in
                            Button {
                                toggleFavorite(run)
                            } label: {
                                Label(run.menuLabel,
                                      systemImage: run.isFavorite ? "star.fill" : "star")
                            }
                        }
                    }
                    Divider()
                    Button("Clear history", role: .destructive) {
                        clearHistoryKeepingFavorites()
                    }
                } label: {
                    Text("Pull a previous run…")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func loadRecentRuns() -> [RecentRun] {
        let raw = settings.eraseInstallRecentRunsJSON
        guard let data = raw.data(using: .utf8),
              let runs = try? JSONDecoder().decode([RecentRun].self, from: data)
        else { return [] }
        return runs
    }

    /// Favorites first (newest within favorites), then the rest by recency.
    private func sortedRecentRuns() -> [RecentRun] {
        loadRecentRuns().sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite && !b.isFavorite }
            return a.timestamp > b.timestamp
        }
    }

    private func saveRecentRuns(_ runs: [RecentRun]) {
        if let data = try? JSONEncoder().encode(runs),
           let str = String(data: data, encoding: .utf8) {
            settings.eraseInstallRecentRunsJSON = str
        }
    }

    private func toggleFavorite(_ run: RecentRun) {
        var runs = loadRecentRuns()
        if let i = runs.firstIndex(where: { $0.id == run.id }) {
            runs[i].isFavorite.toggle()
            saveRecentRuns(runs)
        }
    }

    /// "Clear history" keeps starred entries so the user doesn't lose them.
    private func clearHistoryKeepingFavorites() {
        let kept = loadRecentRuns().filter { $0.isFavorite }
        saveRecentRuns(kept)
    }

    private func applyRecent(_ run: RecentRun) {
        let s = run.spec
        mode = s.mode
        versionPicker = s.versionPicker; versionText = s.versionText
        includeBetas = s.includeBetas; letUserSelectOnHost = s.letUserSelectOnHost
        checkPower = s.checkPower; powerWaitLimit = s.powerWaitLimit; minBattery = s.minBattery
        checkFMM = s.checkFMM; fmmWaitLimit = s.fmmWaitLimit
        minDriveSpace = s.minDriveSpace; rebootDelay = s.rebootDelay
        newVolumeName = s.newVolumeName; preserveContainer = s.preserveContainer
        noFullscreen = s.noFullscreen; showConfirmOnHost = s.showConfirmOnHost
        downloadMethod = s.downloadMethod; cachingServer = s.cachingServer
        cleanupAfterUse = s.cleanupAfterUse; overwriteInstaller = s.overwriteInstaller
        updateIfStale = s.updateIfStale; replaceIfInvalid = s.replaceIfInvalid
        preinstallCommand = s.preinstallCommand; postinstallCommand = s.postinstallCommand
        extraFlags = s.extraFlags
    }

    /// Push the just-built spec onto the front of the saved history.
    /// Favorites are kept regardless of cap; the rolling 10-entry limit
    /// applies only to non-starred entries so the user can't lose a pin.
    static func pushRecent(spec: RunSpec, hostName: String, settings: SettingsStore) {
        var existing: [RecentRun] = []
        if let data = settings.eraseInstallRecentRunsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([RecentRun].self, from: data) {
            existing = decoded
        }
        let new = RecentRun(timestamp: Date(), hostName: hostName, spec: spec)
        let favorites = existing.filter { $0.isFavorite }
        var rolling = existing.filter { !$0.isFavorite }
        rolling.insert(new, at: 0)
        if rolling.count > 10 { rolling = Array(rolling.prefix(10)) }
        let combined = favorites + rolling
        if let encoded = try? JSONEncoder().encode(combined),
           let str = String(data: encoded, encoding: .utf8) {
            settings.eraseInstallRecentRunsJSON = str
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Erase / Reinstall macOS").font(.headline)
                Text("on \(hostnameTarget)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            Section("Mode") {
                Picker("Action", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if mode.isDestructive {
                    Label("Erase wipes the disk. There is no undo.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section("macOS Version") {
                Picker("Target", selection: $versionPicker) {
                    ForEach(VersionPicker.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                if versionPicker.needsValue {
                    LabeledContent("Value") {
                        TextField(versionPlaceholder, text: $versionText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
                Toggle("Include beta releases", isOn: $includeBetas)
                    .help("Adds --beta to the search.")
                Toggle("Let user pick on host", isOn: $letUserSelectOnHost)
                    .help("Adds --select. erase-install shows a swiftDialog list of available versions on the remote Mac.")
            }

            Section("Power & Safety") {
                Toggle("Check AC power before running", isOn: $checkPower)
                    .help("--check-power. Aborts if not on AC and the wait limit elapses.")
                if checkPower {
                    LabeledContent("Power wait (seconds)") {
                        TextField("", text: $powerWaitLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    LabeledContent("Min battery (%)") {
                        TextField("", text: $minBattery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    .help("Leave blank to always check for AC power regardless of battery level.")
                }
                if mode == .erase {
                    Toggle("Check Find My Mac is off", isOn: $checkFMM)
                        .help("--check-fmm. Prompts the user to disable Find My Mac before --erase.")
                    if checkFMM {
                        LabeledContent("FMM wait (seconds)") {
                            TextField("", text: $fmmWaitLimit)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
                LabeledContent("Min free disk (GB)") {
                    TextField("", text: $minDriveSpace)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("Reboot") {
                LabeledContent("Delay (seconds — max 300)") {
                    TextField("", text: $rebootDelay)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            if mode == .erase {
                Section("Erase Options") {
                    LabeledContent("New volume name") {
                        TextField("Macintosh HD", text: $newVolumeName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    .help("--newvolumename. Only used with --erase.")
                    Toggle("Preserve other volumes in APFS container",
                           isOn: $preserveContainer)
                        .help("--preservecontainer. Keeps non-system volumes intact.")
                }
            }

            Section("Host UI") {
                Toggle("Compact dialog (not fullscreen)", isOn: $noFullscreen)
                    .help("--no-fs. Smaller dialog during preparation.")
                Toggle("Show on-host confirmation dialog", isOn: $showConfirmOnHost)
                    .help("--confirm. The remote user gets a confirm dialog before action.")
            }

            Section("Download") {
                Picker("Method (Native = macOS built-in)", selection: $downloadMethod) {
                    ForEach(DownloadMethod.allCases) { Text($0.label).tag($0) }
                }
                .help("Native uses installassistant/softwareupdate built into macOS. mist-cli auto-downloads on first use from GitHub. fetch-full-installer is the legacy softwareupdate path.")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache server URL")
                        .font(.callout)
                    TextField("", text: $cachingServer,
                              prompt: Text(verbatim: "http://cache.example.com:51492"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    Text("Optional. Routes downloads through your local Apple Content Cache.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Lifecycle") {
                Toggle("Clean up workdir after run (LaunchDaemon)",
                       isOn: $cleanupAfterUse)
                    .help("--cleanup-after-use. Removes the installer cache after reboot.")
                Toggle("Overwrite existing installer", isOn: $overwriteInstaller)
                    .help("--overwrite. Delete any cached installer and re-download.")
                Toggle("Update existing installer if stale", isOn: $updateIfStale)
                    .help("--update. Refresh the cached installer to latest.")
                Toggle("Replace cached installer if invalid", isOn: $replaceIfInvalid)
                    .help("--replace-invalid.")
            }

            Section("Scripting Hooks (advanced)") {
                LabeledContent("Pre-install command") {
                    TextField("", text: $preinstallCommand,
                              prompt: Text(verbatim: "Runs before startosinstall"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Post-install command") {
                    TextField("", text: $postinstallCommand,
                              prompt: Text(verbatim: "Runs after install completes"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Extra flags") {
                    TextField("", text: $extraFlags,
                              prompt: Text(verbatim: "--cloneuser --max-password-attempts=infinite"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                if !settings.eraseInstallDefaultFlags.isEmpty {
                    Text("Settings → Erase Install adds: \(settings.eraseInstallDefaultFlags)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if requiresHostnameConfirm {
                Section("Confirm Destructive Run") {
                    TextField("Type the hostname to enable Run",
                              text: $hostnameConfirm,
                              prompt: Text(verbatim: hostnameTarget))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionPlaceholder: String {
        switch versionPicker {
        case .majorOS:          return "e.g. 15"
        case .specificVersion:  return "e.g. 15.4.1"
        case .specificBuild:    return "e.g. 24E263"
        default:                return ""
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will run on \(hostnameTarget):")
                .font(.caption).foregroundStyle(.secondary)
            Text(buildCommand())
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .lineLimit(4).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(runButtonLabel, role: mode.isDestructive ? .destructive : nil) {
                onRun(RunSpec(
                    mode: mode,
                    versionPicker: versionPicker, versionText: versionText,
                    includeBetas: includeBetas, letUserSelectOnHost: letUserSelectOnHost,
                    checkPower: checkPower, powerWaitLimit: powerWaitLimit, minBattery: minBattery,
                    checkFMM: checkFMM, fmmWaitLimit: fmmWaitLimit,
                    minDriveSpace: minDriveSpace, rebootDelay: rebootDelay,
                    newVolumeName: newVolumeName, preserveContainer: preserveContainer,
                    noFullscreen: noFullscreen, showConfirmOnHost: showConfirmOnHost,
                    downloadMethod: downloadMethod, cachingServer: cachingServer,
                    cleanupAfterUse: cleanupAfterUse, overwriteInstaller: overwriteInstaller,
                    updateIfStale: updateIfStale, replaceIfInvalid: replaceIfInvalid,
                    preinstallCommand: preinstallCommand, postinstallCommand: postinstallCommand,
                    extraFlags: extraFlags))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var runButtonLabel: String {
        switch mode {
        case .reinstall: return "Reinstall"
        case .erase:     return "Erase + Reinstall"
        case .list:      return "List installers"
        case .testRun:   return "Test Run"
        }
    }

    // MARK: - Command builder (mirrored exactly in ContentView.runEraseInstall)

    private func buildCommand() -> String {
        EraseInstallSheet.buildCommand(spec: snapshotForPreview(),
                                       scriptPath: settings.eraseInstallPath,
                                       defaultFlags: settings.eraseInstallDefaultFlags)
    }

    private func snapshotForPreview() -> RunSpec {
        RunSpec(
            mode: mode,
            versionPicker: versionPicker, versionText: versionText,
            includeBetas: includeBetas, letUserSelectOnHost: letUserSelectOnHost,
            checkPower: checkPower, powerWaitLimit: powerWaitLimit, minBattery: minBattery,
            checkFMM: checkFMM, fmmWaitLimit: fmmWaitLimit,
            minDriveSpace: minDriveSpace, rebootDelay: rebootDelay,
            newVolumeName: newVolumeName, preserveContainer: preserveContainer,
            noFullscreen: noFullscreen, showConfirmOnHost: showConfirmOnHost,
            downloadMethod: downloadMethod, cachingServer: cachingServer,
            cleanupAfterUse: cleanupAfterUse, overwriteInstaller: overwriteInstaller,
            updateIfStale: updateIfStale, replaceIfInvalid: replaceIfInvalid,
            preinstallCommand: preinstallCommand, postinstallCommand: postinstallCommand,
            extraFlags: extraFlags
        )
    }

    /// Static so ContentView can build the same command without reaching
    /// into a sheet instance.
    static func buildCommand(spec: RunSpec,
                             scriptPath: String,
                             defaultFlags: String) -> String {
        var parts: [String] = ["sudo", scriptPath, spec.mode.flag]

        // Version
        switch spec.versionPicker {
        case .latest: break
        case .sameOS:           parts.append("--sameos")
        case .sameBuild:        parts.append("--samebuild")
        case .majorOS:
            if !spec.versionText.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--os=\(spec.versionText.trimmingCharacters(in: .whitespaces))")
            }
        case .specificVersion:
            if !spec.versionText.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--version=\(spec.versionText.trimmingCharacters(in: .whitespaces))")
            }
        case .specificBuild:
            if !spec.versionText.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--build=\(spec.versionText.trimmingCharacters(in: .whitespaces))")
            }
        }
        if spec.includeBetas         { parts.append("--beta") }
        if spec.letUserSelectOnHost  { parts.append("--select") }

        // Power & safety
        if spec.checkPower { parts.append("--check-power") }
        if spec.checkPower, let v = positiveInt(spec.powerWaitLimit) {
            parts.append("--power-wait-limit \(v)")
        }
        if spec.checkPower, let v = positiveInt(spec.minBattery) {
            parts.append("--min-battery \(v)")
        }
        if spec.mode == .erase && spec.checkFMM {
            parts.append("--check-fmm")
            if let v = positiveInt(spec.fmmWaitLimit) {
                parts.append("--fmm-wait-limit \(v)")
            }
        }
        if let v = positiveInt(spec.minDriveSpace) {
            parts.append("--min-drive-space=\(v)")
        }

        // Reboot
        if let v = positiveInt(spec.rebootDelay) {
            parts.append("--rebootdelay \(v)")
        }

        // Erase-mode tweaks
        if spec.mode == .erase {
            let trim = spec.newVolumeName.trimmingCharacters(in: .whitespaces)
            if !trim.isEmpty { parts.append("--newvolumename \(shq(trim))") }
            if spec.preserveContainer { parts.append("--preservecontainer") }
        }

        // Host UI
        if spec.noFullscreen      { parts.append("--no-fs") }
        if spec.showConfirmOnHost { parts.append("--confirm") }

        // Download method
        parts.append(spec.downloadMethod.flag)
        let cache = spec.cachingServer.trimmingCharacters(in: .whitespaces)
        if !cache.isEmpty { parts.append("--caching-server \(shq(cache))") }

        // Lifecycle
        if spec.cleanupAfterUse    { parts.append("--cleanup-after-use") }
        if spec.overwriteInstaller { parts.append("--overwrite") }
        if spec.updateIfStale      { parts.append("--update") }
        if spec.replaceIfInvalid   { parts.append("--replace-invalid") }

        // Scripting hooks
        let pre = spec.preinstallCommand.trimmingCharacters(in: .whitespaces)
        if !pre.isEmpty { parts.append("--preinstall-command \(shq(pre))") }
        let post = spec.postinstallCommand.trimmingCharacters(in: .whitespaces)
        if !post.isEmpty { parts.append("--postinstall-command \(shq(post))") }

        // Global defaults from Settings + free-form per-run extras. Dedup
        // by flag name against what the structured form already emitted so
        // we never produce e.g. `--check-power --check-power`.
        let alreadyEmitted = collectFlagNames(in: parts)
        let appended = dedupedAppend(
            current: parts,
            extra: [defaultFlags, spec.extraFlags],
            alreadyEmitted: alreadyEmitted
        )
        return appended.joined(separator: " ")
    }

    /// Pull `--name` (with or without `=value`) out of each part that
    /// starts with `--`. Multi-word parts like `"--rebootdelay 60"` are
    /// handled too: we look at characters until the first space or `=`.
    private static func collectFlagNames(in parts: [String]) -> Set<String> {
        var names = Set<String>()
        for p in parts {
            if let n = flagName(of: p) { names.insert(n) }
        }
        return names
    }

    private static func flagName(of token: String) -> String? {
        guard token.hasPrefix("--") else { return nil }
        var name = ""
        for c in token.dropFirst(2) {
            if c == " " || c == "=" { break }
            name.append(c)
        }
        return name.isEmpty ? nil : name
    }

    /// Tokenise the extra flag strings and append only those flags whose
    /// name hasn't already been emitted. A flag with a value (`--foo bar`
    /// or `--foo=bar`) takes the value with it; consecutive non-flag
    /// tokens following a skipped flag are also skipped.
    private static func dedupedAppend(current: [String],
                                      extra: [String],
                                      alreadyEmitted: Set<String>) -> [String] {
        var result = current
        var seen = alreadyEmitted
        for blob in extra {
            let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var i = 0
            while i < tokens.count {
                let t = tokens[i]
                if let name = flagName(of: t) {
                    if seen.contains(name) {
                        // Skip this flag and any value-tokens that follow.
                        i += 1
                        while i < tokens.count, flagName(of: tokens[i]) == nil {
                            i += 1
                        }
                    } else {
                        result.append(t)
                        seen.insert(name)
                        // Consume immediately-following value-tokens.
                        i += 1
                        while i < tokens.count, flagName(of: tokens[i]) == nil {
                            result.append(tokens[i])
                            i += 1
                        }
                    }
                } else {
                    // Stray non-flag token — pass through.
                    result.append(t)
                    i += 1
                }
            }
        }
        return result
    }

    private static func positiveInt(_ s: String) -> Int? {
        let trim = s.trimmingCharacters(in: .whitespaces)
        guard !trim.isEmpty, let v = Int(trim), v > 0 else { return nil }
        return v
    }

    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
