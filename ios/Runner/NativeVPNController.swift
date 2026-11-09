import Flutter
import Foundation
import NetworkExtension
import UIKit

/// Method-channel ownership stays in Runner; native cores live only in the extension.
/// NETunnelProviderManager callbacks are marshalled onto the main queue.
final class NativeVPNController {
    private var channel: FlutterMethodChannel?
    private var manager: NETunnelProviderManager?
    private var loading = false
    private var managerWaiters: [(Result<NETunnelProviderManager, Error>) -> Void] = []
    private var operation = 0
    private var pendingStartAt: Date?
    private var expectedSessionID: String?
    private var localFailure: VPNFailure?

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "happycat.vpn/native", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.channel = channel
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "prepareVpn":
            do { _ = try VPNSharedStore() }
            catch { result(false); return }
            prepare { outcome in
                switch outcome {
                case .success: result(true)
                case .failure: result(false)
                }
            }
        case "startVpn": start(args, result: result)
        case "stopVpn":
            operation += 1
            pendingStartAt = nil
            load { outcome in
                switch outcome {
                case .success(let manager):
                    manager.connection.stopVPNTunnel()
                    result(nil)
                case .failure(let error): result(self.flutterError(error))
                }
            }
        case "getVpnStatus", "getTrafficStats", "getLastStartupError":
            load { outcome in
                switch outcome {
                case .success(let manager):
                    let status = self.status(manager)
                    if call.method == "getVpnStatus" { result(status) }
                    else if call.method == "getLastStartupError" { result(status["errorMessage"]) }
                    else if status["state"] as? String == "running" {
                        result(["tx": status["tx"] ?? 0, "rx": status["rx"] ?? 0])
                    } else { result(nil) }
                case .failure(let error): result(self.flutterError(error))
                }
            }
        case "getNativeVpnDebugLog":
            do { result(try VPNSharedStore().debugLog()) }
            catch { result(flutterError(error)) }
        case "clearNativeVpnDebugLog":
            do { try VPNSharedStore().clearDebugLog(); result(nil) }
            catch { result(flutterError(error)) }
        case "refreshNetwork":
            load { outcome in
                guard case .success(let manager) = outcome,
                      let session = manager.connection as? NETunnelProviderSession,
                      [.connected, .reasserting].contains(session.status) else { result(nil); return }
                do {
                    try session.sendProviderMessage(Data("refreshNetwork".utf8), responseHandler: nil)
                    result(nil)
                } catch { result(self.flutterError(error)) }
            }
        case "openVpnSettings":
            // There is no public URL for the system VPN pane. Open this app's
            // settings; the user can navigate to General > VPN & Device Management.
            guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
            UIApplication.shared.open(url, options: [:]) { result($0) }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func start(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let config = args["config"] as? String, !config.isEmpty,
              config.utf8.count <= VPNConstants.maxConfigBytes,
              let data = config.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            result(FlutterError(code: "INVALID_CONFIG", message: "A valid Xray JSON config is required.", details: nil))
            return
        }
        if let runtime = args["runtime"] as? String, !runtime.isEmpty, runtime != "xray" {
            result(FlutterError(code: "UNSUPPORTED_RUNTIME", message: "iOS uses the Xray runtime.", details: nil))
            return
        }
        operation += 1
        let token = operation
        prepare { outcome in
            guard token == self.operation else {
                result(FlutterError(code: "VPN_CANCELLED", message: "VPN startup was cancelled.", details: nil))
                return
            }
            do {
                let manager = try outcome.get()
                switch manager.connection.status {
                case .connected, .connecting, .reasserting: result(nil); return
                case .disconnecting:
                    throw VPNFailure(code: "VPN_BUSY", message: "Wait for the VPN to stop before reconnecting.")
                default: break
                }
                let store = try VPNSharedStore()
                let sessionID = UUID().uuidString
                try store.write([
                    "config": config, "sessionId": sessionID,
                    "routingMode": args["routingMode"] as? String ?? "all",
                    "updatedAt": VPNSharedStore.now
                ], to: "request.json")
                self.localFailure = nil
                self.expectedSessionID = sessionID
                self.pendingStartAt = Date()
                // executablePath/includePackages/excludePackages are deliberately
                // ignored. The extension uses linked libraries and device-wide routes.
                guard let session = manager.connection as? NETunnelProviderSession else {
                    throw VPNFailure(code: "VPN_SESSION_UNAVAILABLE", message: "The VPN profile is unavailable.")
                }
                try session.startTunnel(options: ["sessionId": sessionID as NSString])
                store.log("runner start accepted")
                result(nil)
            } catch {
                self.pendingStartAt = nil
                self.localFailure = self.failure(error)
                result(self.flutterError(error))
            }
        }
    }

    private func load(_ completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        if let manager = manager { completion(.success(manager)); return }
        managerWaiters.append(completion)
        guard !loading else { return }
        loading = true
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                let outcome: Result<NETunnelProviderManager, Error>
                if let error = error { outcome = .failure(error) }
                else {
                    let existing = managers?.first {
                        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == VPNConstants.providerBundleID
                    }
                    let manager = existing ?? NETunnelProviderManager()
                    self.manager = manager
                    outcome = .success(manager)
                }
                self.loading = false
                let waiters = self.managerWaiters
                self.managerWaiters.removeAll()
                waiters.forEach { $0(outcome) }
            }
        }
    }

    private var preparing = false
    private var prepareWaiters: [(Result<NETunnelProviderManager, Error>) -> Void] = []

    private func prepare(_ completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        prepareWaiters.append(completion)
        guard !preparing else { return }
        preparing = true
        load { outcome in
            switch outcome {
            case .failure: self.finishPrepare(outcome)
            case .success(let manager):
                // Reload to notice revoked/deleted profiles while Runner stayed alive.
                if manager.protocolConfiguration != nil {
                    manager.loadFromPreferences { error in
                        DispatchQueue.main.async {
                            if error != nil { self.manager = nil; self.finishPrepare(.failure(error!)) }
                            else { self.saveIfNeeded(manager) }
                        }
                    }
                } else { self.saveIfNeeded(manager) }
            }
        }
    }

    private func saveIfNeeded(_ manager: NETunnelProviderManager) {
        if manager.isEnabled,
           let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
           proto.providerBundleIdentifier == VPNConstants.providerBundleID {
            finishPrepare(.success(manager))
            return
        }
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = VPNConstants.providerBundleID
        proto.serverAddress = "neuravpn"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "neuravpn"
        manager.isEnabled = true
        manager.saveToPreferences { error in
            if let error = error {
                DispatchQueue.main.async { self.manager = nil; self.finishPrepare(.failure(error)) }
                return
            }
            manager.loadFromPreferences { error in
                DispatchQueue.main.async {
                    if let error = error { self.manager = nil; self.finishPrepare(.failure(error)) }
                    else { self.finishPrepare(.success(manager)) }
                }
            }
        }
    }

    private func finishPrepare(_ outcome: Result<NETunnelProviderManager, Error>) {
        preparing = false
        let waiters = prepareWaiters
        prepareWaiters.removeAll()
        waiters.forEach { $0(outcome) }
    }

    private func status(_ manager: NETunnelProviderManager) -> [String: Any] {
        let store = try? VPNSharedStore()
        let request = store?.read("request.json") ?? [:]
        var shared = store?.read("status.json") ?? [:]
        // A previous extension process must not satisfy a new startup request.
        if pendingStartAt != nil, let expected = expectedSessionID,
           shared["sessionId"] as? String != expected {
            shared = [:]
        }
        var state: String
        switch manager.connection.status {
        case .connecting: state = "starting"
        case .reasserting:
            // A live tunnel recovering after a network change stays "running";
            // reporting "starting" would make the app show a disconnect.
            state = shared["state"] as? String == "running" ? "running" : "starting"
        case .connected:
            pendingStartAt = nil
            expectedSessionID = nil
            state = shared["state"] as? String == "running" ? "running" : "starting"
        case .disconnecting: state = "stopping"
        case .disconnected, .invalid:
            if let started = pendingStartAt, Date().timeIntervalSince(started) < 5 {
                state = "starting"
            } else {
                state = "stopped"
                if pendingStartAt != nil {
                    localFailure = VPNFailure(code: "VPN_START_FAILED", message: "iOS could not start the VPN extension.")
                    pendingStartAt = nil
                }
            }
        @unknown default: state = "stopped"
        }
        if shared["state"] as? String == "error", state != "stopping" {
            state = "error"
        } else if let failure = localFailure, state == "stopped" {
            state = "error"
            shared["errorCode"] = failure.code
            shared["errorMessage"] = failure.message
        }
        let sessionID: Any = shared["sessionId"] ?? (expectedSessionID as Any?) ?? request["sessionId"] ?? NSNull()
        var result: [String: Any] = [
            "state": state, "updatedAt": shared["updatedAt"] ?? VPNSharedStore.now,
            "sessionId": sessionID,
            "routingMode": shared["routingMode"] ?? request["routingMode"] ?? "all",
            "tx": state == "running" ? (shared["tx"] ?? 0) : 0,
            "rx": state == "running" ? (shared["rx"] ?? 0) : 0,
            "errorCode": NSNull(), "errorMessage": NSNull()
        ]
        if state == "error" {
            result["errorCode"] = shared["errorCode"] ?? "VPN_FAILED"
            result["errorMessage"] = shared["errorMessage"] ?? "The VPN extension failed. Connect again."
        }
        return result
    }

    private func failure(_ error: Error) -> VPNFailure {
        if let error = error as? VPNFailure { return error }
        let native = error as NSError
        // Avoid serializing error userInfo; it can contain profile details.
        return VPNFailure(code: "IOS_VPN_\(native.code)",
                          message: "iOS could not update the VPN profile. Check VPN permission and signing.")
    }

    private func flutterError(_ error: Error) -> FlutterError {
        let safe = failure(error)
        return FlutterError(code: safe.code, message: safe.message, details: nil)
    }
}
