import SwiftUI

struct StarButton: View {
    let host: BlueSkyHost
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: host.isFavorite ? "star.fill" : "star")
                .foregroundStyle(host.isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help(host.isFavorite ? "Click to remove from Favorites" : "Click to add to Favorites")
    }
}
