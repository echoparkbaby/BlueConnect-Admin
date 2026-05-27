import Foundation

/// Stable identifier for each section the MunkiReport inventory pane
/// can render. Stored by rawValue in `@AppStorage("mrSectionOrder")` /
/// `@AppStorage("mrSectionHidden")`, so the rawValues must NOT change.
/// New sections added in later versions just get appended to the order
/// at runtime (see `SettingsStore.munkiReportSectionOrder`).
enum MRSection: String, CaseIterable, Codable, Identifiable, Hashable {
    case machine          = "machine"
    case checkIn          = "check-in"
    case localUsers       = "local-users"
    case network          = "network"
    case wifi             = "wifi"
    case munki            = "munki"
    case softwareUpdates  = "software-updates"
    case filevault        = "filevault"
    case disk             = "disk"
    case power            = "power"
    case timemachine      = "timemachine"
    case profiles         = "profiles"
    case pendingInstalls  = "pending-installs"
    case installs         = "installs"

    var id: String { rawValue }

    /// Default display order — used when no AppStorage value is set yet
    /// and as the source of new sections to append after upgrades.
    static let defaultOrder: [MRSection] = [
        .machine, .checkIn, .localUsers,
        .network, .wifi, .munki, .softwareUpdates,
        .filevault, .disk, .power, .timemachine, .profiles,
        .pendingInstalls, .installs,
    ]

    /// Human-facing label used in the Settings reorder list.
    var label: String {
        switch self {
        case .machine:          return "Machine"
        case .checkIn:          return "MunkiReport Check-in"
        case .localUsers:       return "Local Users"
        case .network:          return "Network"
        case .wifi:             return "Wi-Fi"
        case .munki:            return "Munki"
        case .softwareUpdates:  return "Software Updates"
        case .filevault:        return "FileVault"
        case .disk:             return "Storage"
        case .power:            return "Battery"
        case .timemachine:      return "Time Machine"
        case .profiles:         return "Profiles"
        case .pendingInstalls:  return "Pending Installs"
        case .installs:         return "Managed Installs"
        }
    }

    var systemImage: String {
        switch self {
        case .machine:          return "laptopcomputer"
        case .checkIn:          return "antenna.radiowaves.left.and.right"
        case .localUsers:       return "person.2.fill"
        case .network:          return "network"
        case .wifi:             return "wifi"
        case .munki:            return "shippingbox"
        case .softwareUpdates:  return "arrow.down.circle"
        case .filevault:        return "lock.shield"
        case .disk:             return "internaldrive"
        case .power:            return "bolt.batteryblock"
        case .timemachine:      return "clock.arrow.circlepath"
        case .profiles:         return "doc.badge.gearshape"
        case .pendingInstalls:  return "tray.and.arrow.down"
        case .installs:         return "cube.box"
        }
    }
}
