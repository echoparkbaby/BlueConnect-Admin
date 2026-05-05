import Foundation

enum SidebarFilter: Hashable {
    case all
    case favorites
    case recent
    case active
    case inactive
    case uncategorized
    case category(String)

    var key: String {
        switch self {
        case .all: "all"
        case .favorites: "fav"
        case .recent: "recent"
        case .active: "active"
        case .inactive: "inactive"
        case .uncategorized: "uncat"
        case .category(let c): "cat:\(c)"
        }
    }
}
