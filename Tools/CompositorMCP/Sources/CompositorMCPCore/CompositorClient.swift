import Foundation

/// Errors raised by the Compositor bridge.
public enum CompositorError: Error, Equatable {
    case appNotRunning
    case httpError(status: Int, message: String)
    case badResponse
}

extension CompositorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .appNotRunning:
            "Compositor is not running and could not be launched."
        case .httpError(let status, let message):
            "HTTP \(status): \(message)"
        case .badResponse:
            "Compositor returned an unreadable response."
        }
    }
}

/// What the bridge can ask the app to do.
public protocol CompositorAPI: Sendable {
    func health() async throws -> [String: Any]
    func tools() async throws -> [[String: Any]]
    func state() async throws -> Any
    func call(name: String, arguments: [String: Any]?) async throws -> (success: Bool, message: String)
}

/// Talks to the running Compositor over its loopback HTTP API. When the endpoint file is
/// missing, launches the app and waits for it to publish.
public actor CompositorClient: CompositorAPI {
    private var cachedEndpoint: Endpoint?
    private let session: URLSession
    private let autoLaunch: Bool
    private let launchProcess: (@Sendable () async throws -> Void)?

    public init(autoLaunch: Bool = true) {
        self.session = URLSession(configuration: .ephemeral)
        self.autoLaunch = autoLaunch
        self.launchProcess = autoLaunch ? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Compositor"]
            try process.run()
        } : nil
    }

    /// Test/preview initializer with an explicit endpoint and no auto-launch.
    public init(endpoint: Endpoint) {
        self.cachedEndpoint = endpoint
        self.session = URLSession(configuration: .ephemeral)
        self.autoLaunch = false
        self.launchProcess = nil
    }

    private func resolveEndpoint() async throws -> Endpoint {
        if let cachedEndpoint { return cachedEndpoint }
        if let found = EndpointStore.load() {
            cachedEndpoint = found
            return found
        }
        guard autoLaunch, let launchProcess else { throw CompositorError.appNotRunning }
        try await launchProcess()
        for _ in 0..<40 {
            if let found = EndpointStore.load() {
                cachedEndpoint = found
                return found
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CompositorError.appNotRunning
    }

    // MARK: CompositorAPI

    public func health() async throws -> [String: Any] {
        let data = try await request(path: "/v1/health", method: "GET", body: nil)
        return try requireObject(try JSONSerialization.jsonObject(with: data))
    }

    public func tools() async throws -> [[String: Any]] {
        let data = try await request(path: "/v1/tools", method: "GET", body: nil)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CompositorError.badResponse
        }
        return array
    }

    public func state() async throws -> Any {
        let data = try await request(path: "/v1/state", method: "GET", body: nil)
        return try JSONSerialization.jsonObject(with: data)
    }

    public func call(name: String, arguments: [String: Any]?) async throws -> (success: Bool, message: String) {
        let payload: [String: Any] = ["name": name, "arguments": arguments ?? [:]]
        let data = try await request(path: "/v1/call", method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: payload))
        let object = try requireObject(try JSONSerialization.jsonObject(with: data))
        guard let message = object["message"] as? String else { throw CompositorError.badResponse }
        return ((object["success"] as? Bool) ?? false, message)
    }

    // MARK: HTTP

    private func request(path: String, method: String, body: Data?) async throws -> Data {
        let endpoint = try await resolveEndpoint()
        guard let url = URL(string: endpoint.urlString + path) else {
            throw CompositorError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompositorError.appNotRunning
        }
        guard let http = response as? HTTPURLResponse else { throw CompositorError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CompositorError.httpError(status: http.statusCode, message: message)
        }
        return data
    }

    private func requireObject(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CompositorError.badResponse }
        return object
    }
}
