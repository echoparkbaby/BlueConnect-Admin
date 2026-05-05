import Foundation

struct VNCSheetItem: Identifiable {
    let controller: VNCConnectController
    var id: ObjectIdentifier { ObjectIdentifier(controller) }
}
