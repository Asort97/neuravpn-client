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
