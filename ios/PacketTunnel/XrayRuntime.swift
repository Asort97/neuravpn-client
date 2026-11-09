import Foundation
import LibXray

/// libXray v26.7.28's cgo JSON API. All calls belong to the provider's serial queue.
final class XrayRuntime {
    func start(config: String) throws {
        guard config.utf8.count <= VPNConstants.maxConfigBytes,
              let data = config.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = object["inbounds"] as? [[String: Any]],
              inbounds.count == 1,
              inbounds[0]["protocol"] as? String == "socks",
              inbounds[0]["listen"] as? String == "127.0.0.1",
              inbounds[0]["port"] as? Int == 10808 else {
            throw VPNFailure(code: "INVALID_CONFIG", message: "Invalid local SOCKS configuration.")
        }
        try rejectGeoData(object["routing"])
        try rejectGeoData(object["dns"])
        // Do not accept arbitrary env paths or core traffic logs from a payload.
        // Go's iOS runtime explicitly sets GC=10 and a 30 MiB soft limit itself.
        object["env"] = ["xray.buffer.size": "16"]
        object["policy"] = ["levels": ["0": ["bufferSize": 16]]]
        object["log"] = ["loglevel": "none", "access": "none", "dnsLog": false]
        let prepared = try JSONSerialization.data(withJSONObject: object)
        _ = try call("runXrayFromJson", payload: ["configJSON": String(decoding: prepared, as: UTF8.self)])
        guard try isRunning() else {
            throw VPNFailure(code: "XRAY_START_FAILED", message: "Xray did not enter the running state.")
        }
    }

    func stop() throws { _ = try call("stopXray") }

    func isRunning() throws -> Bool {
        (try call("getXrayState")["running"] as? Bool) == true
    }

    private func call(_ method: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "apiVersion": 1, "method": method, "payload": payload
        ])
        var bytes = Array(String(decoding: request, as: UTF8.self).utf8CString)
        let response = bytes.withUnsafeMutableBufferPointer { CGoInvoke($0.baseAddress) }
        guard let response = response else {
            throw VPNFailure(code: "XRAY_API_FAILED", message: "Xray returned an empty response.")
        }
        defer { CGoFree(response) }
        let data = Data(String(cString: response).utf8)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["success"] as? Bool == true else {
            // Raw Go errors may embed UUIDs, server addresses or passwords.
            throw VPNFailure(code: "XRAY_API_FAILED", message: "Xray rejected the \(method) request.")
        }
        return result["data"] as? [String: Any] ?? [:]
    }

    private func rejectGeoData(_ value: Any?) throws {
        if let text = value as? String,
           ["geoip:", "geosite:", "ext:", "ext-ip:"].contains(where: { text.lowercased().hasPrefix($0) }) {
            throw VPNFailure(code: "GEO_DATA_UNSUPPORTED",
                             message: "Use explicit domains or CIDRs on iOS; geo databases are not bundled.")
        }
        if let map = value as? [String: Any] {
            for item in map.values { try rejectGeoData(item) }
        } else if let array = value as? [Any] {
            for item in array { try rejectGeoData(item) }
        }
    }
}
