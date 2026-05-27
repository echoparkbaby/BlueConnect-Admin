import SwiftUI

/// Reusable section-rendering body for a Munki Report inventory record.
/// The standalone sheet (`MunkiReportInventoryView`) AND the right-side
/// inspector pane both use this to render the same sections — keeps the
/// styling consistent and means new fields land in one place.
struct MunkiReportInventoryContent: View {
    let inventory: MRHostInventory
    /// Compact mode trims paddings + font sizes for the narrow inspector
    /// pane (~340pt wide). The standalone sheet runs without compact.
    var compact: Bool = false

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            ForEach(settings.munkiReportSectionOrder) { s in
                if settings.munkiReportSectionIsVisible(s) {
                    section(for: s)
                }
            }
        }
    }

    @ViewBuilder
    private func section(for s: MRSection) -> some View {
        switch s {
        case .machine:          machineSection
        case .checkIn:          reportdataSection
        case .localUsers:       localUsersSection
        case .network:          networkSection
        case .wifi:             wifiSection
        case .munki:            munkiSection
        case .softwareUpdates:  softwareUpdatesSection
        case .filevault:        filevaultSection
        case .disk:             diskSection
        case .power:            powerSection
        case .timemachine:      timeMachineSection
        case .profiles:         profilesSection
        case .pendingInstalls:  pendingInstallsSection
        case .installs:         installsSection
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var machineSection: some View {
        if let m = inventory.machine {
            sectionCard(title: "Machine", systemImage: "laptopcomputer") {
                row("Computer", m.computer_name)
                row("Hostname", m.hostname)
                row("Model", m.machine_desc ?? m.machine_model)
                if !compact { row("Hardware ID", m.machine_model) }
                row("CPU", m.cpu)
                if !compact, let s = m.current_processor_speed { row("Speed", s) }
                if let n = m.number_processors { row("Cores", String(n)) }
                row("Arch", m.cpu_arch)
                row("Memory", m.memoryString)
                row("macOS", m.osVersionString)
                if !compact { row("Build", m.buildversion) }
            }
        }
    }

    @ViewBuilder
    private var reportdataSection: some View {
        if let r = inventory.reportdata {
            sectionCard(title: "MunkiReport Check-in", systemImage: "antenna.radiowaves.left.and.right") {
                if let d = r.lastCheckInDate {
                    row("Last check-in",
                        "\(d.formatted(date: .abbreviated, time: .shortened)) (\(d.formatted(.relative(presentation: .named))))")
                }
                row("Console user", r.console_user)
                if !compact { row("Long username", r.long_username) }
                row("Remote IP", r.remote_ip)
                if let up = r.uptime {
                    row("Uptime", "\(up / 86400)d \((up % 86400) / 3600)h")
                }
            }
        }
    }

    @ViewBuilder
    private var munkiSection: some View {
        if let mr = inventory.munkireport {
            sectionCard(title: "Munki", systemImage: "shippingbox") {
                row("Version", mr.version)
                row("Last run", mr.runtype)
                if !compact {
                    row("Started", mr.starttime)
                    row("Ended", mr.endtime)
                }
                if let e = mr.errors {
                    row("Errors", String(e), severity: e > 0 ? .error : .ok)
                }
                if let w = mr.warnings {
                    row("Warnings", String(w), severity: w > 0 ? .warning : .ok)
                }
                row("Manifest", mr.manifestname)
            }
        }
    }

    @ViewBuilder
    private var filevaultSection: some View {
        if let fv = inventory.filevault {
            sectionCard(title: "FileVault", systemImage: "lock.shield") {
                let on = (fv.filevault_status ?? "").lowercased().contains("on")
                row("Status", fv.filevault_status, severity: on ? .ok : .warning)
                let hasKey = (fv.has_personal_recovery_key ?? 0) == 1
                    || (fv.has_institutional_recovery_key ?? 0) == 1
                row("Recovery key", fv.recoveryKeyStatus,
                    severity: hasKey ? .ok : .warning)
                if !compact { row("Enabled users", fv.filevault_users) }
                if let pct = fv.conversion_percent, pct > 0, pct < 100 {
                    row("Conversion", "\(pct)% — \(fv.conversion_state ?? "in progress")",
                        severity: .warning)
                }
            }
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if let d = inventory.disk_report {
            sectionCard(title: "Storage", systemImage: "internaldrive") {
                row("Volume", d.volumename)
                row("Type", d.media_type?.uppercased())
                row("Total", d.totalString)
                row("Free", d.freeString)
                if let pct = d.percentage { row("Used", "\(pct)%") }
                row("SMART", d.smartstatus,
                    severity: (d.smartstatus ?? "").lowercased() == "verified" ? .ok : .warning)
                if let enc = d.encrypted {
                    row("Encrypted", enc == 1 ? "Yes" : "No",
                        severity: enc == 1 ? .ok : .warning)
                }
            }
        }
    }

    @ViewBuilder
    private var powerSection: some View {
        if let p = inventory.power,
           p.cycle_count != nil || p.condition != nil {
            sectionCard(title: "Battery", systemImage: "bolt.batteryblock") {
                row("Condition", p.condition,
                    severity: (p.condition ?? "").lowercased() == "normal" ? .ok : .warning)
                if let cap = p.max_percent { row("Max capacity", "\(cap)%") }
                if let cycles = p.cycle_count { row("Cycle count", String(cycles)) }
                if let ch = p.current_percent { row("Charge", "\(ch)%") }
                row("AC connected", p.externalconnected)
                row("Charging", p.ischarging)
            }
        }
    }

    @ViewBuilder
    private var localUsersSection: some View {
        // Always render the card — empty state shows when MR hasn't
        // collected local_users data for this Mac yet (module disabled
        // in Munki config, or the host hasn't checked in since the
        // module was added). Hiding the section silently is too
        // ambiguous — looks like a bug instead of a config gap.
        let users = inventory.users ?? []
        if users.isEmpty {
            sectionCard(title: "Local Users",
                        systemImage: "person.2.fill") {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("No local user data reported. Enable MR's `local_users` module on this Mac and wait for it to check in.")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 1)
            }
        } else {
            // Admins first, then by UID. Helps the admin row (usually
            // `ladmin` / 501) jump to the top of fleets where it isn't.
            let sorted = users.sorted { a, b in
                let aAdm = a.admin?.isOn ?? false
                let bAdm = b.admin?.isOn ?? false
                if aAdm != bAdm { return aAdm && !bAdm }
                return (a.uid ?? Int.max) < (b.uid ?? Int.max)
            }
            sectionCard(title: "Local Users (\(users.count))",
                        systemImage: "person.2.fill") {
                ForEach(sorted) { u in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: (u.admin?.isOn ?? false)
                              ? "person.fill.badge.plus"
                              : "person")
                            .foregroundStyle((u.admin?.isOn ?? false) ? .orange : .secondary)
                            .font(.caption)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(u.shortName)
                                    .font(compact ? .caption : .callout)
                                    .lineLimit(1)
                                if let uid = u.uid {
                                    Text("uid \(uid)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if u.admin?.isOn ?? false {
                                    Text("admin")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if let real = u.realname, !real.isEmpty, real != u.shortName {
                                Text(real)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !compact, let home = u.home, !home.isEmpty {
                                Text(home)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 8) {
                                if u.ssh_access?.isOn ?? false {
                                    Label("SSH", systemImage: "terminal")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                                if let d = u.lastLoginDate {
                                    Text("last login \(d.formatted(.relative(presentation: .named)))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if let interfaces = inventory.network, !interfaces.isEmpty {
            // Active (has an address) first, then by service order.
            let sorted = interfaces.sorted { a, b in
                if a.hasAddress != b.hasAddress { return a.hasAddress && !b.hasAddress }
                return (a.service_order ?? Int.max) < (b.service_order ?? Int.max)
            }
            sectionCard(title: "Network", systemImage: "network") {
                ForEach(sorted) { iface in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: iface.hasAddress
                                  ? "circle.fill" : "circle.dashed")
                                .foregroundStyle(iface.hasAddress ? .green : .secondary)
                                .font(.caption2)
                            Text(iface.service_name ?? "Interface")
                                .font(compact ? .caption : .callout).bold()
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                        }
                        if let ip = iface.ipv4ip, !ip.isEmpty {
                            row("IPv4", ip)
                        }
                        if let router = iface.ipv4router, !router.isEmpty, !compact {
                            row("Router", router)
                        }
                        if let dns = iface.ipv4dnsservers, !dns.isEmpty, !compact {
                            row("DNS", dns)
                        }
                        if let mac = iface.ethernet_macaddress, !mac.isEmpty {
                            row("MAC", mac)
                        }
                        if let v6 = iface.ipv6ip, !v6.isEmpty, !compact {
                            row("IPv6", v6)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var wifiSection: some View {
        if let w = inventory.wifi, w.hasAnyField {
            sectionCard(title: "Wi-Fi", systemImage: "wifi") {
                if let ssid = w.ssid, !ssid.isEmpty {
                    row("SSID", ssid)
                }
                if let sec = w.security, !sec.isEmpty {
                    row("Security", sec)
                }
                if let ch = w.channel?.value {
                    row("Channel", String(ch))
                }
                if let rssi = w.rssiLabel {
                    let weak = (w.rssi?.value ?? 0) < -70
                    row("Signal", rssi, severity: weak ? .warning : .ok)
                }
                if !compact, let bssid = w.bssid, !bssid.isEmpty {
                    row("BSSID", bssid)
                }
                if !compact, let rate = w.transmit_rate, !rate.isEmpty {
                    row("TX rate", rate)
                }
                if !compact, let cc = w.country_code, !cc.isEmpty {
                    row("Country", cc)
                }
                if !compact, let svc = w.service, !svc.isEmpty {
                    row("Interface", svc)
                }
            }
        }
    }

    @ViewBuilder
    private var softwareUpdatesSection: some View {
        if let su = inventory.software_updates {
            let pending = su.recommendedupdates?.value ?? 0
            let available = su.lastupdatesavailable?.value ?? 0
            // Hide entirely when MR returned a row but nothing's pending
            // AND no dates exist (likely the host hasn't reported yet).
            let hasData = pending > 0
                || available > 0
                || (su.lastsuccessfuldate?.isEmpty == false)
                || (su.lastfullsuccessfuldate?.isEmpty == false)
            if hasData {
                sectionCard(title: "Software Updates",
                            systemImage: "arrow.down.circle") {
                    if pending > 0 {
                        row("Recommended", "\(pending) pending",
                            severity: pending > 0 ? .warning : .ok)
                    }
                    if available > 0, available != pending {
                        row("Available", "\(available)")
                    }
                    if let restart = su.auto_update_restart_required {
                        row("Auto-update restart", restart.isOn ? "Required" : "Not required",
                            severity: restart.isOn ? .warning : .ok)
                    }
                    if let last = su.lastsuccessfuldate, !last.isEmpty {
                        row("Last check", last)
                    }
                    if let lastFull = su.lastfullsuccessfuldate, !lastFull.isEmpty, !compact {
                        row("Last full install", lastFull)
                    }
                    if let auto = su.auto_update {
                        row("Auto-update", auto.isOn ? "Enabled" : "Disabled")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var profilesSection: some View {
        if let profiles = inventory.profiles, !profiles.isEmpty {
            sectionCard(title: "Profiles (\(profiles.count))",
                        systemImage: "doc.badge.gearshape") {
                let visible = compact ? 6 : 20
                ForEach(profiles.prefix(visible)) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.payload_display ?? p.name ?? p.identifier ?? "—")
                            .font(compact ? .caption : .callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            if let payload = p.payload_name, !payload.isEmpty {
                                Text(payload)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let id = p.identifier, !id.isEmpty, !compact {
                                Text(id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                if profiles.count > visible {
                    Text("… and \(profiles.count - visible) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var timeMachineSection: some View {
        if let tm = inventory.timemachine, tm.hasAnyField {
            sectionCard(title: "Time Machine", systemImage: "clock.arrow.circlepath") {
                if let auto = tm.auto_backup {
                    row("Auto-backup", auto.isOn ? "On" : "Off",
                        severity: auto.isOn ? .ok : .warning)
                }
                if let last = tm.last_success, !last.isEmpty {
                    row("Last backup", last)
                }
                if let dest = tm.server_display_name ?? tm.alias_volume_name,
                   !dest.isEmpty {
                    row("Destination", dest)
                }
                if !compact, let url = tm.network_url, !url.isEmpty {
                    row("Network URL", url)
                }
                if !compact, let id = tm.last_destination_id, !id.isEmpty {
                    row("Destination ID", id)
                }
                if !compact, let snaps = tm.snapshot_dates, !snaps.isEmpty {
                    row("Snapshots", snaps)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingInstallsSection: some View {
        // Prefer the dedicated `pendingupdates` table if MR returned one;
        // otherwise fall back to filtering `managedinstalls` for rows
        // where the agent flagged `installed = false`. Section ALWAYS
        // renders — empty state shows a green "all caught up" so the
        // user can tell at a glance that the data loaded and there's
        // nothing queued (vs. the section silently hiding, which is
        // ambiguous).
        let pending: [MRManagedInstall] = {
            if let p = inventory.pending_installs, !p.isEmpty { return p }
            return (inventory.managed_installs ?? []).filter { !$0.installed }
        }()
        sectionCard(title: pending.isEmpty
                    ? "Pending Installs"
                    : "Pending Installs (\(pending.count))",
                    systemImage: "tray.and.arrow.down") {
            if pending.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Nothing pending — host is up to date.")
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 1)
            } else {
                let visibleCount = compact ? 8 : 20
                ForEach(pending.prefix(visibleCount)) { mi in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(mi.display_name ?? mi.name ?? "—")
                            .font(compact ? .caption : .callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if let v = mi.version {
                            Text(v)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 1)
                }
                if pending.count > visibleCount {
                    Text("… and \(pending.count - visibleCount) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var installsSection: some View {
        if let installs = inventory.managed_installs, !installs.isEmpty {
            sectionCard(title: "Managed Installs (\(installs.count))",
                        systemImage: "cube.box") {
                let visibleCount = compact ? 8 : 20
                ForEach(installs.prefix(visibleCount)) { mi in
                    HStack(spacing: 6) {
                        Image(systemName: mi.installed
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(mi.installed ? .green : .secondary)
                            .font(.caption)
                        Text(mi.display_name ?? mi.name ?? "—")
                            .font(compact ? .caption : .callout)
                            .lineLimit(1)
                        Spacer()
                        if let v = mi.version {
                            Text(v).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                if installs.count > visibleCount {
                    Text("… and \(installs.count - visibleCount) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Section + row primitives

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String, systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(.tint)
                Text(title).font(.subheadline).bold()
            }
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(compact ? 6 : 8)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25)))
        }
    }

    enum Severity { case ok, warning, error }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, severity: Severity = .ok) -> some View {
        if let v = value, !v.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: compact ? 84 : 110, alignment: .leading)
                Text(v)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle({
                        switch severity {
                        case .ok:      return Color.primary
                        case .warning: return Color.orange
                        case .error:   return Color.red
                        }
                    }())
                    .textSelection(.enabled)
                    .lineLimit(compact ? 2 : 4)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}
