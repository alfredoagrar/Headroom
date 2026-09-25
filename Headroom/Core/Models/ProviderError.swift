import Foundation

enum ProviderError: Error, Equatable, Sendable {
    case notConfigured(hint: String)
    case expired(hint: String)
    case unauthorized
    case rateLimited
    case http(Int)
    case network(String)
    case decoding(String)

    var message: String {
        switch self {
        case .notConfigured(let hint): "Sin conectar. \(hint)"
        case .expired(let hint): "Sesión expirada. \(hint)"
        case .unauthorized: "Credenciales rechazadas por el proveedor."
        case .rateLimited: "El proveedor pidió esperar (429). Reintentando luego."
        case .http(let code): "Error del servidor (HTTP \(code))."
        case .network(let detail): "Sin conexión: \(detail)"
        case .decoding(let detail): "Respuesta inesperada: \(detail)"
        }
    }
}
