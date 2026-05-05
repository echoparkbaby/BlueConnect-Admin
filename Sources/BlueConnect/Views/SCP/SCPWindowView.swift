import SwiftUI

/// Root content of the standalone "Send File" Window. Reads the active
/// transfer + host from `SCPController` and embeds the same sheet UI.
struct SCPWindowView: View {
    @Environment(SCPController.self) private var controller

    var body: some View {
        Group {
            if let host = controller.host {
                SCPTransferSheet(host: host, transfer: controller.transfer)
            } else {
                ContentUnavailableView(
                    "No transfer queued",
                    systemImage: "paperplane",
                    description: Text("Drag a file onto a host row, or use the SCP button on a host, to send a file.")
                )
                .frame(width: 480, height: 240)
            }
        }
    }
}
