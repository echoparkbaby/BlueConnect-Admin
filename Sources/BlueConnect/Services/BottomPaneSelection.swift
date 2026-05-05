import Foundation

enum BottomPaneSelection: Hashable {
    case session(UUID)
    case connections
    case log
}
