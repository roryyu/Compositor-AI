import Foundation

/// Errors surfaced by the AI features. Messages are user-facing and English,
/// matching the rest of the app.
nonisolated enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidBaseURL(String)
    case invalidResponse(String)
    case httpStatus(code: Int, message: String, retryAfter: Double? = nil)
    case network(String)
    case decodeFailed(String)
    case imageFailed(String)
    case noDocument
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            "AI is not configured. Set up \(what) in AI Settings."
        case .invalidBaseURL(let url):
            "The AI service URL is not valid: \(url)"
        case .invalidResponse(let detail):
            "The AI service returned an unexpected response. \(detail)"
        case .httpStatus(let code, let message, _):
            "The AI service returned HTTP \(code): \(message.isEmpty ? "no details" : message)"
        case .network(let detail):
            "Could not reach the AI service. \(detail)"
        case .decodeFailed(let detail):
            "The AI service response could not be read. \(detail)"
        case .imageFailed(let detail):
            "The generated image could not be used. \(detail)"
        case .noDocument:
            "Open or create a canvas first."
        case .timeout:
            "The AI service took too long to answer."
        case .cancelled:
            "The AI request was cancelled."
        }
    }

    /// True for errors worth retrying with backoff.
    var isRetryable: Bool {
        switch self {
        case .httpStatus(let code, _, _): code == 429 || (500...599).contains(code)
        case .network, .timeout: true
        default: false
        }
    }
}
