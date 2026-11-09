import Foundation
import Darwin

enum VPNConstants {
    static let appGroup = "group.com.neuravpn.app"
    static let providerBundleID = "com.neuravpn.app.PacketTunnel"
    static let maxConfigBytes = 2 * 1024 * 1024
    static let mtu = 1280
}

struct VPNFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Atomic files avoid UserDefaults cross-process caching. Only the extension
/// writes status; Runner writes requests. A flock protects the shared ring log.
final class VPNSharedStore {
    let directory: URL

    init() throws {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: VPNConstants.appGroup
        ) else {
            throw VPNFailure(code: "APP_GROUP_UNAVAILABLE",
                             message: "The VPN App Group is unavailable. Check signing entitlements.")
        }
        directory = root.appendingPathComponent("VPN", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func read(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value as? [String: Any]
    }

    func write(_ value: [String: Any], to name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func log(_ event: String) {
        // Callers provide lifecycle events/codes only, never configs, addresses,
        // subscription URIs, or raw errors returned by the proxy core.
        withLogLock {
            let url = directory.appendingPathComponent("debug.log")
            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(Data("\(Self.now) \(event)\n".utf8))
            if data.count > 64 * 1024 {
                data = Data(data.suffix(48 * 1024))
                if let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
            }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func debugLog() -> String {
        var result = ""
        withLogLock {
            result = (try? String(contentsOf: directory.appendingPathComponent("debug.log"),
                                  encoding: .utf8)) ?? ""
        }
        return result
    }

    func clearDebugLog() {
        withLogLock {
            try? Data().write(to: directory.appendingPathComponent("debug.log"), options: .atomic)
        }
    }

    private func withLogLock(_ body: () -> Void) {
        let fd = open(directory.appendingPathComponent("debug.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        body()
    }
}
