# neuravpn native iOS architecture

## Scope and verification status

The app uses a real Network Extension implementation: libXray and
hev-socks5-tunnel run inside `PacketTunnel.appex`, never inside Flutter. No VPN
method is a success-only placeholder. This change was developed on Windows;
an iOS compile, a signed device installation and actual network traffic have
**not** been verified. The first macOS Actions run is still a required build gate.

Deployment target is iOS **15.0** for Runner, the extension and Pods. The installed
`mobile_scanner 7.4.2/darwin/mobile_scanner.podspec` requires iOS 12.0; libXray's
pinned Apple archive and HEV's Apple build use iOS 15.0. No Dart dependency or
`pubspec.yaml` change was needed.

## Files and ownership

| Location | Responsibility |
| --- | --- |
| `Runner/AppDelegate.swift` | Channel registration, device info, cold/warm import URLs |
| `Runner/NativeVPNController.swift` | VPN profile permission, save/reload, start/stop, system status reconciliation |
| `Runner/NativeHaptics.swift` | Prepared UIKit feedback generators |
| `Shared/VPNSharedStore.swift` | App Group files, file protection, bounded lifecycle log |
| `PacketTunnel/PacketTunnelProvider.swift` | Routes/DNS, lifecycle, recovery, status writer |
| `PacketTunnel/XrayRuntime.swift` | libXray v1 JSON invoke API, C string ownership, bounded config |
| `PacketTunnel/PacketFlowBridge.swift` | Public packetFlow API to HEV datagram fd, traffic counters |
| `PacketTunnel/PacketTunnel.xcconfig` | Extension build/link settings, Flutter version values only |
| `Runner/Info.plist`, `PacketTunnel/Info.plist` | Host/extension metadata and extension entry point |
| `Runner/Runner.entitlements`, `PacketTunnel/PacketTunnel.entitlements` | Network Extension and shared App Group capabilities |
| `Runner.xcodeproj/project.pbxproj` | Target, dependency, static XCFramework linkage, Embed App Extensions phase |
| `Podfile`, `Flutter/Debug.xcconfig`, `Flutter/Release.xcconfig`, `Flutter/AppFrameworkInfo.plist` | Flutter plugin integration and deployment target |
| `scripts/prepare_native.sh` | Download/check libXray; download/check/build HEV iOS XCFramework |
| `scripts/validate_project.py` | Portable OpenStep parser, ID/reference/target/plist checks |
| `.gitignore` | Excludes native binaries, download cache and iOS build output |
| `../.github/workflows/ios.yml` | macOS unsigned build, IPA packaging and artifact upload |
| `../lib/services/android_vpn_controller.dart` | Historical Dart bridge now supports Android and iOS |
| `../lib/services/vpn_core_controller.dart` | Shared native runtime gating and `isMobileNativeRuntime` getter |
| `../lib/vless/config_generator.dart` | Additive `generateIOSXrayConfig`; Android generator is unchanged |
| `../test/ios_native_runtime_test.dart`, `../test/ios_xray_config_test.dart` | iOS gating, lifecycle, channel payload, traffic and config coverage |

`main.dart`, widgets, Android and Windows sources belong to the frontend agent
and were not edited for this implementation. Existing Android-named Dart APIs
remain callable on iOS; the frontend can use `isMobileNativeRuntime` to select
them. Per-app controls should remain hidden on iOS.

## Data flow

```text
Flutter -> happycat.vpn/native -> NETunnelProviderManager
                                    |
                           Network Extension process
                                    |
NEPacketTunnelFlow <-> bounded AF_UNIX datagram pair <-> HEV
                                                       |
                                      SOCKS5 TCP/UDP 127.0.0.1:10808
                                                       |
                                            libXray -> VPN server
```

`prepareVpn` checks the shared container and creates/saves/enables the profile
when needed. Saving triggers Apple's permission UI. Runner reloads preferences
before using a saved profile. It never considers a successful `startTunnel`
request proof of a running VPN.

Runner atomically writes `VPN/request.json` in `group.com.neuravpn.app`, including
config, routing mode and a fresh session UUID. That UUID is also supplied in
`startTunnel` options. A mismatched request is rejected. Starts from system VPN
Settings without Flutter options reuse the saved config with a new UUID.

The extension starts Xray before installing the default routes and DNS settings.
IPv4 is `172.19.0.1/30`, IPv6 is `fdfe:dcba:9876::1/126`, MTU is 1280, and DNS is
the virtual peer `172.19.0.2`. HEV forwards TCP and UDP through Xray's SOCKS inbound.
The Dart config sends port 53 to `dns-out`; public A/AAAA resolution uses the same
Quad9/Cloudflare DoH configuration as Android. Explicit smart-routing domains
retain Android's system-resolver exception. Both IPv4 and IPv6 default routes
are captured; no interface or captured network is bound to core sockets.

HEV's Apple backend expects a four-byte big-endian address-family prefix. The
packet bridge adds/removes that header around `NEPacketTunnelFlow.readPackets`
and `writePackets`. It uses no `socket.fileDescriptor` KVC, private API, utun
scanning or direct access to the system-owned TUN descriptor. HEV owns neither
socket-pair descriptor; the bridge closes them after worker shutdown. Backpressure
drops packets instead of building an unbounded queue. TCP retransmits.

Only the extension writes `status.json`, including cumulative HEV byte counters
once per second. Runner reconciles that snapshot with `NEVPNStatus`, filters an
old session during startup, and reports stopped when the OS disconnects even if
an extension crash left a stale running snapshot. Starting/reasserting is not
reported as running. A short five-second grace period covers propagation of a
just-accepted start to `NEVPNStatus`.

The lifecycle debug log is shared, flock-protected and capped at 64 KiB (trimmed
to 48 KiB). It records events and fixed error codes, not destinations, raw Xray
errors, UUID credentials or subscription URLs. File snapshots are atomic and
protected until first user authentication after reboot; the VPN directory is
excluded from backup. Config persists after stop so a system-Settings start works.

## Channel contract

### `happycat.vpn/native`

| Method | Arguments | Result / iOS behavior |
| --- | --- | --- |
| `prepareVpn` | none | `bool`; creates/enables/saves profile, false on permission/signing/storage failure |
| `startVpn` | `config`, optional `runtime`, `executablePath`, `includePackages`, `excludePackages`, `routingMode` | `null` after OS accepts request; runtime must be absent/empty/`xray`; path/package lists ignored |
| `stopVpn` | none | `null` after stop request; status polling observes completion |
| `getVpnStatus` | none | `{state, sessionId, updatedAt, errorCode, errorMessage, routingMode, tx, rx}` |
| `getTrafficStats` | none | `{tx, rx}` while running, otherwise `null`; cumulative bytes, upload/download |
| `getNativeVpnDebugLog` | optional `runtime` | lifecycle log `String`; runtime ignored |
| `clearNativeVpnDebugLog` | optional `runtime` | `null`; runtime ignored |
| `getLastStartupError` | none | current persisted extension error or Runner startup error as `String?` |
| `refreshNetwork` | none | requests a debounced core recovery through provider IPC; `null` |
| `openVpnSettings` | none | `bool`; opens **app Settings** via the public URL, not the system VPN pane |

States are `starting`, `running`, `stopping`, `stopped`, `error`; timestamps are
Unix milliseconds. `errorCode` and `errorMessage` are nullable. iOS has no public
deep link to the VPN settings pane: use Settings → General → VPN & Device
Management when necessary. App-specific routing would require a managed-device
deployment and is not implemented; domain/CIDR routing remains inside Xray.

### `neuravpn/haptics`

- `impact`: `{style: light|medium|heavy|soft|rigid, intensity?: double}`. Finite
  intensity is clamped to 0…1. Missing intensity uses the generator's default.
- `selection`: no arguments.
- `notification`: `{type: success|warning|error}`.

Generators are retained, prepared before use, and prepared again afterwards.
Unknown methods return `FlutterMethodNotImplemented`; unknown style/type returns
a Flutter error. UIKit calls execute on Flutter's main platform thread. Devices
without a haptic engine may produce no physical feedback.

### Device info and import URLs

`neuravpn/device_info.getDeviceInfo` returns
`{os: "iOS", model: UIDevice.model, noBackupDirectory: <Application Support/NoBackup>}`.
The model is a general device family, not a hardware model identifier.

`neuravpn/android_launch` deliberately preserves the existing Dart channel name:
`getInitialLaunchUri` returns/consumes the pending cold-start URI, and warm links
invoke Dart's `handleLaunchUri(String)`. Links arriving before Dart's initial
query remain queued. Flutter's automatic deep-link routing is disabled to avoid
double delivery. Registered schemes are `neuravpn`, `vless`, `hysteria2`, `hy2`.

The continuation handler understands Android's two HTTPS host/path pairs, but
**Universal Links are not enabled**. They require Associated Domains entitlement
and valid AASA files on each domain. Registering `http`/`https` as custom URL
schemes would not implement Universal Links, so those schemes are not registered.

## Recovery and stop behavior

A single serial queue owns all Go calls and extension lifecycle transitions.
HEV runs its blocking main function on a separate queue; the packet pump has its
own queue. Cancellation generations invalidate late network-settings callbacks
and pending recoveries. HEV v2.19.3 also latches a quit issued before worker init.

`NWPathMonitor`, `wake()` and `refreshNetwork` request a debounced restart of
Xray, preserving HEV, the packet flow, routes, counters and session UUID. The
extension sets `reasserting` during recovery; failed restart attempts are retried
up to three times, then it records `VPN_RECOVERY_FAILED` and cancels the tunnel.
Loss of the path waits for an available path rather than consuming retries.
Sleep cancels pending retries; wake schedules fresh recovery. The profile uses
`disconnectOnSleep = false`. OS routing chooses each newly created socket's path.
Existing TCP sessions can fail during a handoff and must reconnect.

Stop cancels monitors/timers, asks HEV to quit, waits for its worker to release its
descriptor and then stops Xray. A native stop that hangs is ultimately subject to
Network Extension's OS watchdog; there is no Android-style process-kill fallback.
No always-on/on-demand rules are configured. OS termination due to memory pressure
does not guarantee an automatic restart.

## Memory choices

- Neither geo database is copied into the extension, nor is Flutter linked there.
  The standard Android config and bundled smart whitelist use explicit names and
  CIDRs. User-supplied `geoip:`, `geosite:`, `ext:`, `ext-ip:` rules are rejected on
  iOS rather than silently changing routing. Runner's existing Flutter asset bundle
  still contains Android/Windows assets; this does not load them into the extension.
- libXray **v26.7.28** calls `memory.InitForceFree()` on start. Its iOS build explicitly
  applies `debug.SetGCPercent(10)`, `debug.SetMemoryLimit(30 * 1024 * 1024)` and
  `debug.FreeOSMemory()` every second. These runtime calls are effective even if
  the Go runtime initialized before Swift; late `setenv("GOMEMLIMIT", …)` is not
  relied on. No second Go runtime is linked.
- `policy.levels.0.bufferSize = 16` KiB and config env `xray.buffer.size = "16"`
  bound core buffers. HEV uses 24 KiB task stacks, 16 KiB TCP buffers, 64 KiB UDP
  receive buffers, four UDP copy buffers and at most 64 sessions. At the limit
  HEV evicts an older session. This is a deliberate memory/parallelism tradeoff.
- Socket buffers request 64 KiB each; packet batches are bounded to 32 on the
  HEV→system leg. Configs are limited to 2 MiB, logs to 64 KiB, and status writes
  occur once per second. Native traffic logging is disabled.

The Go limit is **soft and excludes native allocations**. These choices do not
prove the process fits a roughly 50 MB extension budget. VLESS/Reality, Hysteria2,
QUIC, XHTTP and many simultaneous sockets need signed-device memory profiling.

## CI and unsigned artifact

`../.github/workflows/ios.yml` runs on `macos-15` for pushes to `feature/ios-client`
and `master`, or `workflow_dispatch`. Flutter is pinned to **3.38.3**, and Actions
are pinned by commit. No Apple account, certificate, profile or team ID is needed
for the compile/package job.

The workflow embeds these SHA-256 values and the download script checks them
before extraction/build, printing the computed values:

| Input | SHA-256 |
| --- | --- |
| libXray v26.7.28 `libxray-apple-cgo.zip` | `07f7ed7697277930e1c517755855950f594f41435b0dfc5917a66eea6278aeb9` |
| HEV 2.19.3 `hev-socks5-tunnel-2.19.3.tar.xz` | `8aaa33b344cab03a5cfc3675b9aaae55c6ee6088d78678ad1fbb44855b5ba570` |

Both archives were downloaded and their hashes independently computed on Windows.
The libXray archive's actual module map, C header and iOS/simulator slices were
inspected (`CGoInvoke(char*)`, `CGoFree(char*)`, module `LibXray`). HEV's official
release does not provide a prebuilt Apple XCFramework. CI builds a static
XCFramework from its verified source distribution, following its Apple script for
device arm64 and simulator arm64/x86_64 only; unnecessary macOS/tvOS slices are
omitted. Native binaries and the local inspection cache are ignored by git.

After `flutter pub get`, native preparation and `pod install`, the job executes
`flutter build ios --release --no-codesign`. An `XCODE_XCCONFIG_FILE` override
disables signing for **all targets**, including the extension. Packaging checks
the `.appex`, both bundle IDs, matching build numbers and absence of geo/Flutter
assets in the extension. The artifact `neuravpn-ios-unsigned` contains
`neuravpn-unsigned.ipa`, entitlements and this document. The IPA layout is
`Payload/Runner.app/PlugIns/PacketTunnel.appex`. It is not installable until signed.

## Checks performed and remaining gates

Windows checks completed:

- `flutter analyze --no-pub lib/services/android_vpn_controller.dart lib/services/vpn_core_controller.dart lib/vless/config_generator.dart test/ios_native_runtime_test.dart test/ios_xray_config_test.dart`: no issues.
- Targeted `flutter test --no-pub`: **65 passing tests**, covering these tests,
  existing controller tests, Xray config tests and Android/Windows lifecycle
  regression tests. CI runs the portable subset; existing Android lifecycle tests
  use host-specific binary lookup and were verified on Windows.
- `python ios/scripts/validate_project.py`: all 91 Xcode IDs resolve; both targets,
  dependency, embed phase, Debug/Release/Profile configurations, referenced source
  files, plists and entitlements pass structural checks.
- Workflow YAML parses, `bash -n ios/scripts/prepare_native.sh` succeeds, and
  `git diff --check` reports no whitespace errors in the owned changes.
- Full `flutter analyze --no-pub`: 261 findings in the concurrently edited
  frontend/other files and local build probes; no findings in the changed native
  Dart service/config/test files. That count is a snapshot of this shared checkout.

Still unverified: CocoaPods resolution on macOS, Swift type checking/linking,
unsigned archive production, signing, VPN permission, real packet transport,
IPv4/IPv6/DNS leak behavior, sleep/wake and Wi-Fi/cellular recovery, memory/CPU
under load, haptic hardware and QR/import behavior on a real iPhone. HEV has no
readiness callback: startup checks Xray state and observes early HEV worker exits
for 200 ms; running means local runtime readiness, not a successful proxy-server
reachability test.

Publisher TODOs:

1. Push the reviewed work or run the workflow after it is present on GitHub;
   confirm its macOS build and download the artifact. This change was not committed
   or pushed, and no Actions job was launched from Windows.
2. Register App IDs `com.neuravpn.app` and `com.neuravpn.app.PacketTunnel` under one
   Apple Developer team. Register `group.com.neuravpn.app` and enable App Groups
   and Network Extensions for both identifiers. Set `DEVELOPMENT_TEAM` on both
   Xcode targets for a signed build, or supply equivalent profiles when re-signing.
3. Use matching provisioning profiles and entitlements for Runner and the extension.
   Sign nested bundles/frameworks and `PacketTunnel.appex` before Runner. Preserve
   the App Group and packet-tunnel entitlements. The `.entitlements` files alone
   do not grant capabilities in an unsigned IPA. Keep host/extension versions equal.
4. Test on a provisioned physical iPhone: permission accept/reject, cancel while
   starting, normal/forced stop, app relaunch with a running tunnel, Settings start,
   server failure, Wi-Fi↔cellular, airplane mode, sleep/wake, DNS A/AAAA/non-IP
   queries and both IP families. Profile extension memory near the OS budget with
   Hysteria2/QUIC/XHTTP and many concurrent connections; tune the session cap only
   after measurement. Validate App Store rules and upstream license notices before
   distribution.
5. Optional HTTPS import parity: add Associated Domains on Runner, serve valid
   `apple-app-site-association` files for `asort97.github.io/neuravpn-site` and
   `webhook.staticdeliverycdn.com/merged-sub/` under domains you can configure.
   Domain-owner cooperation is required for the latter. Custom schemes work
   without this setup.

Upstream evidence: [libXray pinned release](https://github.com/XTLS/libXray/releases/tag/v26.7.28),
[iOS memory implementation](https://github.com/XTLS/libXray/blob/v26.7.28/memory/memory_ios.go),
[C API](https://github.com/XTLS/libXray/blob/v26.7.28/cgo_bridge/main.go),
[HEV release](https://github.com/heiher/hev-socks5-tunnel/releases/tag/2.19.3),
[Apple build](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.3/build-apple.sh),
[Apple packet framing](https://github.com/heiher/hev-socks5-tunnel/blob/2.19.3/src/hev-tunnel.h).
