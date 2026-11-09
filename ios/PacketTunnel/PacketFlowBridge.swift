import Darwin
import Foundation
import NetworkExtension
import HevSocks5Tunnel

/// HEV's Apple backend accepts a datagram fd with a four-byte, big-endian
/// address-family header. A socket pair connects it to the public packetFlow
/// API; no private socket.fileDescriptor KVC or utun descriptor scanning.
final class PacketFlowBridge {
    private let flow: NEPacketTunnelFlow
    private let lifecycle: DispatchQueue
    private let packets = DispatchQueue(label: "com.neuravpn.packets", qos: .userInitiated)
    private let worker = DispatchQueue(label: "com.neuravpn.hev", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var pumpFD: Int32 = -1
    private var pumping = false // packets queue only
    private var started = false // lifecycle queue only
    private var stopping = false
    private var stopCallbacks: [() -> Void] = []
    var onUnexpectedExit: (() -> Void)?

    init(flow: NEPacketTunnelFlow, lifecycle: DispatchQueue) {
        self.flow = flow
        self.lifecycle = lifecycle
    }

    func start() throws {
        precondition(!started)
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw VPNFailure(code: "TUN_BRIDGE_FAILED", message: "Could not create the packet bridge.")
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var yes: Int32 = 1
            var size: Int32 = 64 * 1024
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let nativeFD = fds[1]
        let localFD = fds[0]
        started = true
        packets.async {
            self.pumpFD = localFD
            self.pumping = true
            let source = DispatchSource.makeReadSource(fileDescriptor: localFD, queue: self.packets)
            source.setEventHandler { [weak self] in self?.readFromHEV() }
            source.setCancelHandler { close(localFD) }
            self.source = source
            source.resume()
            self.readFromSystem()
        }
        worker.async {
            let config = """
            tunnel:
              mtu: 1280
              ipv4: 172.19.0.1
              ipv6: 'fdfe:dcba:9876::1'
            socks5:
              address: 127.0.0.1
              port: 10808
              udp: 'udp'
            misc:
              task-stack-size: 24576
              tcp-buffer-size: 16384
              udp-recv-buffer-size: 65536
              udp-copy-buffer-nums: 4
              max-session-count: 64
              connect-timeout: 10000
              tcp-read-write-timeout: 300000
              udp-read-write-timeout: 60000
              log-level: error
              log-file: null
            """
            let bytes = Array(config.utf8)
            _ = bytes.withUnsafeBufferPointer {
                hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), nativeFD)
            }
            close(nativeFD) // HEV never closes a caller-owned descriptor.
            self.lifecycle.async {
                self.started = false
                self.stopPump()
                let callbacks = self.stopCallbacks
                self.stopCallbacks.removeAll()
                callbacks.forEach { $0() }
                if !self.stopping { self.onUnexpectedExit?() }
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        stopping = true
        stopPump()
        guard started else { completion(); return }
        stopCallbacks.append(completion)
        // v2.19.3 latches a quit requested before its worker has initialized.
        hev_socks5_tunnel_quit()
    }

    func stats() -> (tx: UInt64, rx: UInt64) {
        guard started, !stopping else { return (0, 0) }
        var tx: size_t = 0
        var rx: size_t = 0
        hev_socks5_tunnel_stats(nil, &tx, nil, &rx)
        return (UInt64(max(0, tx)), UInt64(max(0, rx)))
    }

    private func stopPump() {
        packets.async {
            self.pumping = false
            self.source?.cancel()
            self.source = nil
            self.pumpFD = -1
        }
    }

    private func readFromSystem() {
        guard pumping else { return }
        flow.readPackets { [weak self] batch, families in
            guard let self = self else { return }
            self.packets.async {
                guard self.pumping else { return }
                for (packet, family) in zip(batch, families) {
                    guard packet.count <= VPNConstants.mtu else { continue }
                    var header = family.uint32Value.bigEndian
                    var framed = Data(bytes: &header, count: 4)
                    framed.append(packet)
                    // Bounded socket buffers apply backpressure by dropping
                    // packets on EAGAIN. TCP retransmits; never queue unbounded Data.
                    _ = framed.withUnsafeBytes {
                        send(self.pumpFD, $0.baseAddress, $0.count, 0)
                    }
                }
                self.readFromSystem()
            }
        }
    }

    private func readFromHEV() {
        guard pumping else { return }
        var buffer = [UInt8](repeating: 0, count: 65539)
        var batch: [Data] = []
        var families: [NSNumber] = []
        for _ in 0..<32 {
            let length = buffer.withUnsafeMutableBytes {
                recv(pumpFD, $0.baseAddress, $0.count, 0)
            }
            if length <= 0 { break }
            guard length > 4 else { continue }
            let family = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { continue }
            batch.append(Data(buffer[4..<length]))
            families.append(NSNumber(value: family))
        }
        if !batch.isEmpty { _ = flow.writePackets(batch, withProtocols: families) }
    }
}
