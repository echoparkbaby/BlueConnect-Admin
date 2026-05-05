import Foundation

enum APIError: LocalizedError {
    case badURL
    case badResponse(Int, String)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badURL: "Bad server URL"
        case .badResponse(let code, let body):
            "HTTP \(code)\n\(body.prefix(200))"
        case .decoding(let e): "Decode error: \(e.localizedDescription)"
        case .network(let e): "Network error: \(e.localizedDescription)"
        }
    }
}
