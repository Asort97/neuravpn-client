# Full Xray subscription support

Release targets: Android 1.0.16 (16), Windows 1.0.12 (12).

## Implementation

- Windows and Android request `application/vnd.neuravpn.xray+json`, retain the
  installation HWID and send OS version, model and the real NeuraVPN version.
- Each JSON object is stored as one complete profile. URI/base64 VLESS and
  Hysteria 2 imports remain supported. Profile names use `remarks`.
- One Xray instance owns all candidates, leastPing, observatory, the original
  DNS/rules and blackhole fallback. No first-outbound extraction, direct fallback
  or additional startup network check is introduced.
- Platform adapters rebuild local loopback listeners and protect the external
  sockets. Windows uses its existing sing-box TUN bridge. Android keeps its
  existing VpnService/socket-protection and network-recovery implementation.
- Untrusted APIs, file references, scripts, socket controls, insecure TLS and
  unsafe balancer fallbacks are rejected. Runtime logs do not expose the imported
  configuration. Android backup of saved profiles is disabled.
- Explicit device denial replaces that subscription's keys and cancels an
  affected running connection; a late older refresh cannot restore those keys.
  Transport failures retain existing profiles. Quick Tile configuration for the
  affected current selection is removed.
- Manual Android availability checks run the entire profile and require HTTPS
  success, not a ping to the first candidate. No selected route is inferred from
  the exit IP; the client does not add a new active-route display.

## Verification

- Flutter suite: 262 passed, one opt-in network integration test skipped.
- Android release unit tests: 47 passed.
- Isolated real Windows Xray integration: HTTPS payload through VLESS TCP/TLS,
  XHTTP/TLS and Hysteria2/TLS with Salamander; leastPing failover after stopping
  the selected test server; Hysteria2-only availability; all candidates stopped
  without a direct fallback. Selection is asserted from the actual access log.
- Bundled Windows Xray and sing-box accept the generated configs, including
  REALITY TCP/XHTTP settings. This is not a live REALITY-server handshake test.
- New parser/adapter modules pass static analysis. Analysis of the wider changed
  modules has no errors, but retains existing unused/deprecated-code diagnostics.
- Tests use synthetic credentials and local listeners. No active VPN session,
  system route, certificate store or physical network was changed.

## Device acceptance still required

ADB had no connected device. Real Android traffic, screen-off recovery and
Wi-Fi/mobile handoff have not been rerun with this release. These existing
service paths are covered by native tests, not claimed as device validation.

After installing, refresh the existing subscription and select its automatic
profile. The server must have full-JSON/autoselect enabled for this subscription;
otherwise the normal URI profiles remain available. Existing connections are
not migrated by leastPing; only new connections use the currently selected path.

Local build/test logs are under `build/autoselect-*.log` and
`build/android-release/`. No release is automatically published by this change.

## Android artifact

- `build/android-release/NeuraVPN-1.0.16+16.aab`: 139120200 bytes.
- SHA-256: `2AD6D5D0C12811EAE5A0D7C11B821F79943F33A92EA844FBDE4ED29341D1EC25`.
- `bundletool validate` succeeded; `jarsigner -verify` reports `jar verified`.
  Self-signed upload-certificate/no-timestamp warnings are expected.
- Upload certificate SHA-256 matches the previous release:
  `A6:F6:6A:62:A3:23:1A:30:D2:F6:FB:39:30:C1:F2:45:69:51:C6:CC:78:68:F7:81:76:95:C8:E7:D9:56:5C:1B`.
- Manifest: `com.neuravpn.app`, version 1.0.16 / 16, min SDK 24, target SDK 36,
  no debuggable flag. ARM64, ARMv7 and x86_64 libraries and geodata are present.
- No Windows executable/driver or Zapret assets in the AAB. Bundle configuration
  requests native-library 16 KB alignment.

## Windows artifacts

- Release executable reports `1.0.12+12`; installer reports `1.0.12`.
- `build/neuravpn-setup-v1.0.12.exe`: 58082025 bytes.
  SHA-256: `B78FCB0DCE222221FFD9BF6598CC0F693CDCADD216C658B21D3F16527D38CA40`.
- `build/neuravpn-windows-v1.0.12.zip`: 95781931 bytes.
  SHA-256: `377800AED3E9CE584E77BF59076E4867B4654FF2A45D1530F590494B502E76EA`.
- Built through the existing release script (application, updater, archive and
  Inno Setup). Neither the installer nor the VPN application was launched.
