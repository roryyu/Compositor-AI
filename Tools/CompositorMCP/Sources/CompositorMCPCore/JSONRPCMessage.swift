import Foundation

/// Minimal JSON-RPC 2.0 helpers used by the MCP stdio transport. Messages are one JSON
/// object per line with no embedded newlines.
public enum JSONRPCMessage {
    public static func response(id: Any?, result: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    public static func error(id: Any?, code: Int, message: String, data: Any? = nil) -> String {
        var payloadError: [String: Any] = ["code": code, "message": message]
        if let data { payloadError["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": payloadError])
    }

    public static func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { return nil }
        return object
    }

    public static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
