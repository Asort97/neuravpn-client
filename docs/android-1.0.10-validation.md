# NeuraVPN Android 1.0.10+10

## Release scope

- Android package: `com.neuravpn.app` (unchanged).
- Android version name/code: `1.0.10` / `10`.
- Windows release metadata remains `1.0.9` / `9`; no Windows release was built or published.
- First distribution target: Google Play Internal testing, NOT production.
- The AAB is an upload artifact, not a directly installable APK.

## Changes

- Android LibXray upgraded from Xray 26.2.6 to official 26.7.28. The native bridge now uses the versioned JSON invoke API and config-root environment for the geodata path. Provenance and hashes are in `android/app/libs/README.md`.
- Android DNS entering the TUN is handled by Xray. Public A/AAAA resolution uses cached DoH through the proxy; smart-routing exceptions use the physical network's DNS and direct outbound.
- DoH requests inherit the protected DNS routing tag. Domain-only routing uses `AsIs`, avoiding an unnecessary preliminary lookup; IP rules still use `IPIfNonMatch`.
- Non-A/AAAA requests receive an explicit refusal instead of being forwarded to the virtual DNS peer and hanging. Applications with unusual DNS record requirements need device testing.
- Physical-network selection excludes VPN interfaces and updates on network/link-property changes. Outbound sockets are protected and bound to the selected underlying network.
- Session-aware, atomic cross-process state, structured startup errors, native-operation serialization, and cleanup ownership protect repeated start/stop and service recreation.
- Startup returns as soon as the local service is running. There are no added DNS/TCP/HTTP health checks. Slow cold starts have a 30-second ceiling; a timed-out start is cancelled.
- Normal shutdown releases native resources without killing the process. A separate 15-second stop watchdog can terminate ONLY the dedicated `:xray_vpn` process if native shutdown hangs.
- Traffic counters carry a session ID; counters from a previous connection are ignored.
- The Quick Settings configuration is encrypted with Android Keystore. Native diagnostic messages are sanitized and Xray access/config logging is disabled.
- Android settings expose auto-connect, Always-on VPN settings, and Play In-App Updates. Debug/non-Play installations do not download Windows releases.
- Three swipeable sections, mobile connection panel, compact ping and smart-routing switch, long-press/drag actions, reduced-motion handling, lazy app-list loading, and reconnect prompting for app-routing changes.
- Mobile subscription search and bottom-sheet actions for refresh, rename, and delete. Refreshing an unrelated subscription does not replace the selected connection.
- Mobile animation uses 52 small WebP frames with lazy decoding instead of eagerly decoding the desktop PNG sequence.
- Android release assets exclude desktop executables, drivers, Zapret, full-size animation frames, and the unused standalone Android Xray executable.
- Release builds require the existing release keystore; debug-signing fallback was removed.

## Automated verification

Run from the repository root with Flutter on PATH and JDK 17 configured:

```powershell
flutter test --no-pub --reporter expanded
Push-Location android
.\gradlew.bat :app:testDebugUnitTest --max-workers=2
Pop-Location
.\tool\release.ps1 -Action build -Platform android
```

- Flutter: 151 tests passed, including DNS config, VLESS transports, subscription import, lifecycle, manual availability checks and UI tests.
- Native: 20 tests passed, covering atomic state, duplicate starts, stale-session cleanup, DNS endpoint formatting, log redaction, shutdown watchdog behavior, the LibXray JSON API contract, isolated probe configuration and IPC cancellation/timeouts.
- One earlier concurrent Flutter run reported a single failure; the focused rerun and final full 151-test run passed. That intermittent failure was not diagnosed. The final full-run log is `build/android-validation/profile-check-suite.log`.
- Dart analysis of changed modules: zero errors; 10 unused-element warnings in `main.dart` and existing informational lints/deprecations remain.
- UI test viewports: 320, 360 and 480 px portrait; 760 x 360 landscape; system text scale up to 1.6; keyboard and safe-area scenarios.
- Golden images: `test/goldens/android_connection.png`, `android_routing.png`, `android_settings.png`.
- Golden images are Flutter test renders, NOT screenshots from a physical phone. They were inspected manually because Lazyweb MCP was unavailable.
- `bundletool validate` and `jarsigner -verify` passed for the signed release artifact.
- Manifest: package/version above, min SDK 24, target SDK 36, not debuggable.
- ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`; LibXray, tun2socks and geodata present.
- All 64-bit native libraries have LOAD alignment at least 16 KB; bundle requests `PAGE_ALIGNMENT_16K`. The 32-bit LibXray library uses 4 KB alignment. This is an artifact check, not a 16 KB device-runtime test.
- Animation payload: 52 WebP files, approximately 219 KiB total encoded size. An earlier release-mode device snapshot measured UI-process PSS 122879 KiB / RSS 215352 KiB; this is not total VPN-process memory or a sustained animation benchmark.

## Physical-device validation, 2026-09-05

- Device: OnePlus Nord 2 (DN2103), Android 13 / API 33, 1080 x 2400.
- Installed 1.0.10+10 over the existing debug-signed installation without clearing its subscriptions/settings. The latest installed candidate is a debug APK with the updated kernel. This is not a Play-signed upgrade test.
- Initial candidate entered the running state but traffic failed. Telegram was NOT in the six excluded applications. The failure also reproduced through the local SOCKS inbound, outside TUN/DNS interception.
- Sanitized core diagnostics identified REALITY handshake rejection. Happ's working profile matched NeuraVPN's server, port, UUID, SNI, public key, Short ID and flow. Refreshing the subscription did not change these values. Happ's log identified Xray 26.7.28.
- A/B test on the SAME phone/network with the SAME generated configuration: standalone Xray 26.2.6 failed HTTPS (curl exit 35); 26.7.28 returned HTTP 200 in 0.513 s. This establishes a runtime-version-dependent failure for this profile, not the exact server-side handshake rejection condition.
- Updated in-app LibXray also returned HTTPS 200 through SOCKS in 0.293 s. Its local start request to native connected log took approximately 171 ms, excluding Flutter work, VPN consent and remote traffic establishment.
- An external Java diagnostic running under the Android shell UID used normal system DNS/HTTPS while NeuraVPN captured the device network. YouTube, DTF and ya.ru returned HTTP 200; initial DNS timings were approximately 53-124 ms.
- Repeated system-network checks downloaded 71084 bytes of YouTube HTML, a complete 15223-byte Roblox avatar image from rbxcdn.com, and 69403 bytes of DTF HTML. Totals were 539 / 710 / 1060 ms respectively. Cached DNS lookups were 20-27 ms. The Roblox thumbnail API also returned the image URL through the proxy.
- An IPv6-only ipify endpoint failed its TLS connection both through the device TUN and through SOCKS directly. The IPv4 endpoint worked. Do NOT claim end-to-end IPv6 readiness or a passed DNS-leak audit from these results; verify the upstream's IPv6 reachability separately.
- Existing smart-routing OFF and blacklist settings were preserved during testing. Full smart-routing, network-handoff, Always-on and Tile validation remain below.
- Screens were captured from the phone. A nested-scroll interaction in the subscription list still needs a usability pass. No Lazyweb MCP tools were available.
- The user subsequently confirmed that the Android client works well. They did not provide a separate result for every app/network scenario in the production checklist below.
- Diagnostics were manual QA only: no health checks were added to the connection path. No PC VPN was switched or stopped.

## Manual configuration availability checks

- Android-only button in the subscription search field checks all loaded profiles, including collapsed or search-filtered rows. Duplicate URIs are checked once. Selection and the connection path are unchanged.
- Each profile uses its real generated VLESS/REALITY/TCP/XHTTP outbound in a private `:xray_probe` process. No TUN is established, no main VPN runtime methods are called, and no direct outbound or smart-routing bypass is present in the probe config.
- A loopback HTTP CONNECT proxy carries a GET to `https://www.gstatic.com/generate_204`, with `https://cp.cloudflare.com/generate_204` as fallback. Only HTTP 204 after normal platform TLS certificate/hostname validation counts as success. Both endpoints returned 204 during implementation checks.
- Server-bootstrap DNS uses the selected physical network's DNS, with protected/bound sockets. Test-target hostnames travel through the selected VLESS outbound. Failure to bypass an existing VPN is a neutral check error, not a green result through the wrong tunnel.
- Checks run serially with bounded HTTP timeouts, a 20-second IPC deadline, progress and cancellation. After the scan, the native service is unbound so Android can reclaim its process. No checks run automatically during VPN startup. Configurations are passed through private IPC in memory, never written to probe files or logs.
- Small row icons distinguish success, failed HTTPS, local check errors, queue and in-progress states. Tooltips show timing and the observation time. Results expire after five minutes and are not persisted.
- Nine added Flutter tests cover transport generation, deduplication, cancellation, stale/deleted profiles, network failures, hidden rows, selection preservation and 320/360/480 px layouts at 1.5 text scale. `test/goldens/android_profile_availability.png` was rendered and inspected manually.
- Six added native tests cover strict status acceptance, isolated routing, delayed replies, cancellation, unavailable bindings and timeouts.
- ADB no longer detected the phone during this feature's implementation. Real-device scanning, traffic continuity during scanning, cancellation under network failure and comparison of good/bad credentials are still required. The successful device VPN tests above predate this new button.
- A successful probe confirms that HTTPS traffic passed through that profile at the recorded time. It does not certify every website, UDP, IPv6, DNS-routing behavior of the main VPN, or sustained throughput.

## Mobile cleanup and device verification, 2026-09-07

- Android subscription search was replaced by a full-width availability button with a label, stable layout under text scaling, scan progress and cancellation. All profiles, including collapsed subscriptions, are checked without changing selection.
- Removed mobile developer mode, app-launch auto-connect and manual update checking. Previously saved developer/auto-connect flags are ignored on mobile; Windows preferences and behavior remain intact. Android system Always-on VPN remains a separate OS capability.
- Update discovery is silent, coalesced once per app launch, and uses only Google Play. Debug/sideloaded installations are ineligible without displaying errors or falling back to GitHub. A conditional update action is displayed only when Play offers a flexible update or reports a downloaded update. Native install events deliver completion without periodic release checks. Resuming reconciles only an already pending download.
- The existing isolated Xray HTTPS probe is unchanged. Flutter now also requires the native `HTTPS_OK` result code before accepting `available`; ping, TCP and TLS-only results cannot produce a green mark. DNS configuration and main VPN routing were not changed.
- Installed a new debug 1.0.10+10 APK over the existing USB-connected DN2103 installation, preserving its seven configurations, selected third profile and smart-routing setting. Installation stopped the old Android process; the VPN was manually reconnected to the same profile for QA. No PC VPN was touched.
- On the phone, all seven configurations produced green HTTPS results. Progress was captured at 1/7. A quick second press cancelled a new scan and returned unfinished results to unknown. Main VPN session ID and runtime PID remained unchanged during checks/cancellation and navigation.
- System-network HTTPS smoke requests with the selected third profile returned YouTube HTTP 200 / 71295 bytes / 608 ms and Roblox HTTP 200 / 62503 bytes / 1037 ms. These are homepage checks, not a complete media, UDP, IPv6 or leak audit.
- Captured and inspected the installed profile list, scan progress/results, cancellation and simplified settings screen in `build/android-validation/mobile-cleanup-*.png`. Wi-Fi ADB was unreachable at the supplied TUN address; USB was used after the user connected it. No Lazyweb MCP tool was available; UI verification used device captures and local goldens.
- Full Flutter suite: 170 passed, one pre-existing Windows log-throttling test failed at `test/vpn_core_controller_windows_lifecycle_test.dart:1094`. All mobile tests passed; 320/360/480 px availability goldens cover 1.5 text scale. Play update tests were rerun after the final state-handling adjustment: 5 passed.
- Native unit tests: 20 passed. `:app:testDebugUnitTest :app:assembleDebug` succeeded. Analysis of changed Dart modules/tests reported no errors, with existing unused/deprecation diagnostics remaining in shared UI code.
- Debug APK: `build/app/outputs/apk/debug/app-debug.apk`. The AAB below is an older artifact and DOES NOT contain the auto-switch and September 7 cleanup changes. It must be rebuilt and revalidated before publication. No Play/GitHub upload was performed.
- Real Play download/install still needs an eligible Play-installed build; the USB APK validates silent ineligibility, not the complete store upgrade path. See [the official flexible-update lifecycle](https://developer.android.com/guide/playcore/in-app-updates/kotlin-java).

## Earlier AAB Artifact (Before September 7 Changes)

- Historical record only: the file at the following path was replaced by the fresh September 7 release build documented below.
- File: `build/android-release/NeuraVPN-1.0.10+10.aab`.
- Size: 130280428 bytes (124.2 MiB), including the manual HTTPS-check feature.
- SHA-256: `0B5CFA6C4695BDF91227F297F175F78A77CDC09740A3F172D5CC57021F465008`.
- Debug APK for the existing USB test installation: `build/app/outputs/apk/debug/app-debug.apk`. Version 1.0.10+10, same debug certificate, all three supported ABIs. It has been built and signature-checked, but not installed because no ADB device was connected.
- Upload certificate SHA-256: `A6:F6:6A:62:A3:23:1A:30:D2:F6:FB:39:30:C1:F2:45:69:51:C6:CC:78:68:F7:81:76:95:C8:E7:D9:56:5C:1B`.
- This matches the existing local upload key. Google Play's installed-app signing certificate can differ from the upload certificate.

## Fresh signed AAB, 2026-09-07

- Rebuilt with `tool/release.ps1 -Action build -Platform android` after the mobile cleanup and automatic profile-switch changes. No source behavior or Windows version was changed during this build.
- File: `build/android-release/NeuraVPN-1.0.10+10.aab`, copied from `build/app/outputs/bundle/release/app-release.aab`.
- Size: 129627322 bytes (123.62 MiB). This is the multi-ABI upload size, not the per-device Play download size.
- SHA-256: `85653D7947D12905359433D6484EF85E83D25B39FBA91B3746A426F5837E9520`.
- `bundletool validate` and `jarsigner -verify` passed. Signer SHA-256 matches the existing upload certificate listed above. Jarsigner reports the existing self-signed certificate and lack of timestamp; signature verification succeeded.
- Manifest: `com.neuravpn.app`, version `1.0.10`, version code `10`, minimum SDK 24, target SDK 36; no debuggable flag.
- All three ABIs are present: arm64-v8a, armeabi-v7a and x86_64. All 64-bit native libraries have LOAD alignment at least 16384; bundle configuration specifies `PAGE_ALIGNMENT_16K`.
- LibXray, tun2socks, geoip/geosite and 52 mobile WebP frames are present. Desktop binaries, desktop animation directories and unused standalone Android Xray executable are absent.
- Tests were not rerun for this artifact-only rebuild; the latest test/device results are in the September 7 section above.
- The user reports that the earlier two-week Google Play testing requirement was completed. This build does not repeat that enrollment/testing requirement. Current Play Console version-code availability, acceptance and rollout were not checked or performed.

## Required before production

The USB-connected phone was used for the checks above. No authenticated Play Console upload integration was available. No release has been uploaded or rolled out by this work; the signed AAB is a candidate for Internal testing, not production approval.

- [ ] Upload AAB to the existing app's Internal testing track; confirm version code 10 is available there and signing is accepted.
- [ ] Install via that testing track and verify upgrade from the current Play version without losing subscriptions/settings.
- [ ] Test initial VPN permission denial/grant, notification permission, repeated start/stop, process death, app reopening, Quick Settings Tile and Always-on VPN.
- [ ] Test Wi-Fi/mobile handoff, loss/recovery of connectivity, IPv4-only and IPv6-capable networks, screen lock and background operation.
- [ ] Complete actual-app YouTube playback/Roblox/Telegram checks, public IP and DNS-leak testing with smart routing both on and off; repeat after network handoff. The HTTP/CDN smoke tests above passed with smart routing off.
- [ ] With smart routing on, verify Russian-domain bypass uses the physical network as intended. Physical DNS for bypass/server bootstrap is an explicit exception, not a promise of zero local-DNS traffic.
- [ ] Check whitelist/blacklist app routing and the reconnect prompt after changing the app list.
- [ ] Check subscription HTTPS import, clipboard and VLESS links on the real device.
- [ ] Verify HTTPS App Links server-side association. `autoVerify` in the manifest alone is insufficient: the host must serve `/.well-known/assetlinks.json` with the installed-app signing fingerprint, then Android domain verification must succeed.
- [ ] Check Play update flows using eligible Play-installed versions; confirm debug/sideload fallback messaging.
- [ ] Measure connection time, animation/process memory, Play download size, and installed size. The multi-ABI AAB size is not the per-device download size.
- [ ] Capture physical-device screens with large text/keyboard/rotation; inspect through Lazyweb if it becomes available.
- [ ] Approve production rollout only after these device and Play gates pass.

## Reference points

- [Android socket protection](https://developer.android.com/reference/android/net/VpnService#protect(int)) and [per-socket network binding](https://developer.android.com/reference/android/net/Network#bindSocket(java.io.FileDescriptor)): the manual probe must not accidentally reuse the active VPN route.
- [LibXray v26.7.28 API](https://github.com/XTLS/libXray/tree/v26.7.28): structured invoke, socket protection and protected system DNS.
- [Xray v26.7.28 DNS outbound implementation](https://github.com/XTLS/Xray-core/blob/v26.7.28/proxy/dns/dns.go): A/AAAA handling and `nonIPQuery` behavior.
- [Android 16 KB compatibility checks](https://developer.android.com/guide/practices/page-sizes): ELF and bundle alignment checks do not replace runtime testing.
