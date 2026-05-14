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

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            machineSection
            reportdataSection
            munkiSection
            filevaultSection
            diskSection
            powerSection
            installsSection
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
            sectionCard(title: "Check-in", systemImage: "antenna.radiowaves.left.and.right") {
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
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}
