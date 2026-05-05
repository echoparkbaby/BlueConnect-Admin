import Foundation

extension BlueSkyHost {
    var activeSortKey: Int { active ? 0 : 1 }
    var usernameSortKey: String { (username ?? "").lowercased() }
    var statusSortKey: String { (status ?? "").lowercased() }
    var favoriteSortKey: Int { isFavorite ? 0 : 1 }
}
