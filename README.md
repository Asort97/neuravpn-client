# neuravpn

## Secret Management

Do not commit passwords, keys, or production VPN links into git.

### Android signing

1. Copy `android/key.properties.example` to `android/key.properties`.
2. Set strong unique values for `storePassword` and `keyPassword`.
3. Keep `android/key.properties` and `*.jks` local only.

You can also avoid `key.properties` and use env vars:

```powershell
$env:ANDROID_KEYSTORE_PATH = "android/app/neuravpn-release.jks"
$env:ANDROID_KEY_ALIAS = "neuravpn"
$env:ANDROID_KEY_PASSWORD = "your-strong-password"
$env:ANDROID_KEYSTORE_PASSWORD = "your-strong-password"
flutter build apk --release
```

### Windows MSIX signing

Set certificate password only at build time, for example in PowerShell:

```powershell
$env:MSIX_CERTIFICATE_PASSWORD = "your-strong-password"
flutter pub run msix:create --certificate-password $env:MSIX_CERTIFICATE_PASSWORD
```

Do not store `certificate_password` in `pubspec.yaml`.

### Env template

Use `.env.example` as a local template for secret values.

## Platform Version Workflow

Use `release.bat` (or `tool/release.ps1`) to keep Android and Windows versions independent.

Show current config:

```powershell
.\release.bat show
```

Set Android version:

```powershell
.\release.bat set -Platform android -BuildName 1.4.0 -BuildNumber 1403
```

Set Windows version:

```powershell
.\release.bat set -Platform windows -BuildName 1.5.0 -BuildNumber 1501
```

Build Android release APK:

```powershell
.\release.bat build -Platform android
```

Build Android split-per-abi:

```powershell
.\release.bat build -Platform android -SplitPerAbi
```

Build Windows release:

```powershell
.\release.bat build -Platform windows
```

Version storage file: `tool/release_versions.json`

## Windows Runtime Core

- Windows runtime now uses `xray-core` (`assets/bin/xray.exe`).
- Keep `assets/bin/xray.exe` up to date before Windows release builds.
- Android runtime remains on Libbox/sing-box for now.

## Privacy Policy

Google Play listing should point to a public copy of [PRIVACY_POLICY.md](PRIVACY_POLICY.md).
