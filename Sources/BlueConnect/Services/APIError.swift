import Foundation

enum APIError: LocalizedError {
    case badURL
    case badResponse(Int, String)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Bad server URL"
        case .badResponse(let code, let body):
            // 404 specifically means the BlueConnect Admin endpoints aren't
            // deployed on the BSC server. Stock BlueSkyConnect doesn't ship
            // them — they live in the `server/` directory of this repo and
            // need to be copied to the server's web root once.
            if code == 404 {
                return """
                The server responded but doesn't have the BlueConnect Admin endpoints (HTTP 404).

                Stock BlueSkyConnect doesn't ship the JSON API this app needs. Ask whoever runs the BSC server to deploy the PHP files from the BlueConnect-Admin repo's `server/` directory — see https://github.com/echoparkbaby/BlueConnect-Admin#server-setup
                """
            }
            return "HTTP \(code)\n\(body.prefix(200))"
        case .decoding(let e):
            return "Decode error: \(e.localizedDescription)"
        case .network(let e):
            return "Network error: \(e.localizedDescription)"
        }
    }
}
