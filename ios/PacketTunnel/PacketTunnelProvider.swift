import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    // libXray and HEV are process-global; serialize every start/stop/recovery.
    private static let runtimeQueue = DispatchQueue(label: "com.neuravpn.runtime")
    private var queue: DispatchQueue { Self.runtimeQueue }
    private let xray = XrayRuntime()
    private var store: VPNSharedStore?
    private var bridge: PacketFlowBridge?
    private var monitor: NWPathMonitor?
    private var statsTimer: DispatchSourceTimer?
    private var recoveryWork: DispatchWorkItem?
    private var sessionID = ""
    private var routingMode = "all"
    private var runtimeConfig: String?
    private var phase = "stopped"
    private var generation = 0
    private var recoveryGeneration = 0
    private var sleeping = false
    private var pathAvailable = true
    private var terminalFailure: VPNFailure?
    private var startCompletion: ((Error?) -> Void)?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            guard self.phase == "stopped" else {
                completionHandler(VPNFailure(code: "VPN_BUSY", message: "VPN is already active."))
                return
            }
            self.generation += 1
            let token = self.generation
            self.startCompletion = completionHandler
            self.terminalFailure = nil
            self.sleeping = false
            self.pathAvailable = true
            self.sessionID = options?["sessionId"] as? String ?? UUID().uuidString
            self.routingMode = "all"
            do {
                let store = try VPNSharedStore()
                self.store = store
                guard let request = store.read("request.json"),
                      let config = request["config"] as? String else {
                    throw VPNFailure(code: "INVALID_CONFIG", message: "No saved VPN configuration.")
                }
                let requestedID = options?["sessionId"] as? String
                if let requestedID = requestedID, request["sessionId"] as? String != requestedID {
                    throw VPNFailure(code: "STALE_START", message: "The VPN start request was superseded.")
                }
                self.routingMode = request["routingMode"] as? String ?? "all"
                self.runtimeConfig = config
                self.writeState("starting")
                store.log("extension start requested")
                // Bootstrap SOCKS before capturing DNS and the default routes.
                try self.xray.start(config: config)
                self.setTunnelNetworkSettings(self.networkSettings()) { error in
                    self.queue.async {
                        guard token == self.generation, self.phase == "starting" else { return }
                        if error != nil {
                            self.fail(VPNFailure(code: "TUN_SETTINGS_FAILED",
                                                 message: "iOS could not apply the VPN network settings."))
                            return
                        }
                        do {
                            let bridge = PacketFlowBridge(flow: self.packetFlow, lifecycle: self.queue)
                            bridge.onUnexpectedExit = { [weak self] in
                                guard let self = self, token == self.generation else { return }
                                self.fail(VPNFailure(code: "TUN_BRIDGE_EXITED",
                                                     message: "The packet bridge exited unexpectedly."))
                            }
                            self.bridge = bridge
                            try bridge.start()
                            // HEV has no readiness callback. Observe early worker
                            // failures before reporting the local runtime ready.
                            self.queue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                                guard token == self.generation, self.phase == "starting" else { return }
                                self.writeState("running")
                                self.finishStart(nil)
                                self.startMonitoring()
                                self.store?.log("extension running")
                            }
                        } catch {
                            self.fail(self.safeFailure(error, fallback: "TUN_BRIDGE_FAILED"))
                        }
                    }
                }
            } catch {
                self.fail(self.safeFailure(error, fallback: "VPN_START_FAILED"))
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.store?.log("extension stop requested reason=\(reason.rawValue)")
            let preserveError = self.terminalFailure != nil
            if !preserveError { self.writeState("stopping") }
            self.finishStart(VPNFailure(code: "VPN_CANCELLED", message: "VPN startup was cancelled."))
            self.tearDown {
                if !preserveError { self.writeState("stopped") }
                completionHandler()
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            if String(data: messageData, encoding: .utf8) == "refreshNetwork" {
                self.scheduleRecovery()
                completionHandler?(Data("ok".utf8))
            } else {
                completionHandler?(nil)
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        queue.async {
            self.sleeping = true
            self.recoveryGeneration += 1
            self.recoveryWork?.cancel()
            self.store?.log("extension sleep")
            completionHandler()
        }
    }

    override func wake() {
        queue.async {
            self.sleeping = false
            self.store?.log("extension wake")
            self.scheduleRecovery()
        }
    }

    private func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: VPNConstants.mtu)
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["172.19.0.2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
    }

    private func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.phase == "running" || self.phase == "starting" else { return }
            self.writeState(self.phase)
        }
        statsTimer = timer
        timer.resume()
        let monitor = NWPathMonitor()
        var first = true
        var lastInterfaces: [String] = []
        let token = generation
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self, token == self.generation else { return }
            let wasAvailable = self.pathAvailable
            self.pathAvailable = path.status == .satisfied
            // Restart the core only on a real handoff (Wi-Fi <-> cellular,
            // network lost/back), not on cost or constraint flag updates.
            let interfaces = path.availableInterfaces.map(\.name)
            let handoff = interfaces != lastInterfaces || wasAvailable != self.pathAvailable
            lastInterfaces = interfaces
            if first {
                first = false
                if !self.pathAvailable { self.reasserting = true }
                return
            }
            guard handoff else { return }
            self.store?.log(self.pathAvailable ? "network available" : "network unavailable")
            if self.pathAvailable {
                self.scheduleRecovery()
            } else {
                self.recoveryGeneration += 1
                self.recoveryWork?.cancel()
                self.reasserting = true
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    private func scheduleRecovery(attempt: Int = 0) {
        guard !sleeping, pathAvailable, runtimeConfig != nil,
              phase == "running" || phase == "starting" else { return }
        recoveryWork?.cancel()
        recoveryGeneration += 1
        let recoveryToken = recoveryGeneration
        let token = generation
        reasserting = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, token == self.generation,
                  recoveryToken == self.recoveryGeneration,
                  !self.sleeping, self.pathAvailable,
                  let config = self.runtimeConfig else { return }
            do {
                // Stay "running" for the app: recovery is internal, and the
                // app's status poll would otherwise show a disconnect flash.
                // `reasserting` already tells iOS the tunnel is reconnecting.
                self.store?.log("core recovery attempt=\(attempt + 1)")
                try self.xray.stop()
                // Keep the packet flow, HEV, routes, DNS and session. New
                // sockets use system routing; never bind to a captured path.
                try self.xray.start(config: config)
                self.reasserting = false
                self.writeState("running")
                self.store?.log("core recovery complete")
            } catch {
                if attempt < 2 { self.scheduleRecovery(attempt: attempt + 1) }
                else {
                    self.fail(VPNFailure(code: "VPN_RECOVERY_FAILED",
                                         message: "Could not restore the VPN connection. Connect again."))
                }
            }
        }
        recoveryWork = work
        queue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.6 : Double(attempt)), execute: work)
    }

    private func writeState(_ state: String, failure: VPNFailure? = nil) {
        phase = state
        let traffic = bridge?.stats() ?? (tx: 0, rx: 0)
        var value: [String: Any] = [
            "state": state, "sessionId": sessionID, "routingMode": routingMode,
            "updatedAt": VPNSharedStore.now, "tx": traffic.tx, "rx": traffic.rx
        ]
        if let failure = failure {
            value["errorCode"] = failure.code
            value["errorMessage"] = failure.message
        }
        do { try store?.write(value, to: "status.json") }
        catch { store?.log("status write failed") }
    }

    private func fail(_ failure: VPNFailure) {
        terminalFailure = failure
        writeState("error", failure: failure)
        store?.log("extension failure code=\(failure.code)")
        let wasStarting = startCompletion != nil
        tearDown {
            self.finishStart(failure)
            if !wasStarting { self.cancelTunnelWithError(failure) }
        }
    }

    private func tearDown(completion: @escaping () -> Void) {
        generation += 1
        recoveryGeneration += 1
        recoveryWork?.cancel()
        recoveryWork = nil
        monitor?.cancel()
        monitor = nil
        statsTimer?.cancel()
        statsTimer = nil
        runtimeConfig = nil
        reasserting = false
        let finish = {
            try? self.xray.stop()
            self.bridge = nil
            self.phase = "stopped"
            completion()
        }
        if let bridge = bridge { bridge.stop(completion: finish) }
        else { finish() }
    }

    private func finishStart(_ error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }

    private func safeFailure(_ error: Error, fallback: String) -> VPNFailure {
        (error as? VPNFailure) ?? VPNFailure(code: fallback, message: "The VPN runtime could not start.")
    }
}
