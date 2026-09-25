import Foundation

/// The published location of Compositor's loopback control API.
public struct Endpoint: Codable, Sendable, Equatable {
    public var scheme: String
    public var host: String
    public var port: Int
    public var token: String

    public init(scheme: String, host: String, port: Int, token: String) {
        self.scheme = scheme; self.host = host; self.port = port; self.token = token
    }

    public var urlString: String { "\(scheme)://\(host):\(port)" }
}

/// Finds the endpoint file published by the running app.
public enum EndpointStore {
    public static let bundleID = "com.wonderassembly.compositor"

    /// Where the file may live: the sandbox container (released app) and the standard
    /// Application Support (unsigned / non-sandboxed development builds).
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Library/Containers/\(bundleID)/Data/Library/Application Support/Compositor/control.json",
            "\(home)/Library/Application Support/Compositor/control.json",
        ]
    }

    /// Loads the first readable endpoint file.
    public static func load(paths: [String] = candidatePaths()) -> Endpoint? {
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            if let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data) {
                return endpoint
            }
        }
        return nil
    }
}
