# MSIX + App Installer updates (Windows)

This project supports packaging the Windows build as an **MSIX** and publishing updates via **App Installer** (auto-updates from GitHub Releases).

## 1) Pick your app identity

Edit `pubspec.yaml` → `msix_config`:
- `identity_name`: e.g. `com.neuravpn.client`
- `msix_version`: must be `A.B.C.D` (4 numbers). Example: `1.0.1.0`

## 2) Create a signing certificate

MSIX must be signed.

### Local testing (self-signed)

Create a self-signed code-signing certificate and export it:

```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=neuravpn" -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable
$pwd = ConvertTo-SecureString -String "YOUR_PASSWORD" -Force -AsPlainText
New-Item -Force -ItemType Directory .\windows\certificates | Out-Null
Export-PfxCertificate -Cert $cert -FilePath .\windows\certificates\neuravpn.pfx -Password $pwd | Out-Null
Export-Certificate -Cert $cert -FilePath .\appinstaller\neuravpn.cer | Out-Null
```

Trust the certificate:

```powershell
Import-Certificate -FilePath .\appinstaller\neuravpn.cer -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
Import-Certificate -FilePath .\appinstaller\neuravpn.cer -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
```

If the installer still says the certificate is not trusted, repeat the same two `Import-Certificate` commands in an **Administrator PowerShell** but to:
- `Cert:\LocalMachine\TrustedPeople`
- `Cert:\LocalMachine\Root`

Helper scripts:
- Current user: `powershell -ExecutionPolicy Bypass -File .\appinstaller\install_cert_current_user.ps1`
- Local machine (admin): `powershell -ExecutionPolicy Bypass -File .\appinstaller\install_cert.ps1`

### Production (recommended)

Use a real trusted code-signing certificate so users do not have to trust a self-signed cert.

## 3) Build MSIX

```powershell
flutter pub get
flutter build windows --release
flutter pub run msix:create
```

The MSIX file will be created under `build\windows\x64\runner\Release\` (exact path depends on Flutter/MSIX tool versions).

## 4) Publish on GitHub Releases

Upload these assets to each release:
- `neuravpn.msix`
- `neuravpn.appinstaller`
- `neuravpn.cer`

Update `appinstaller/neuravpn.appinstaller`:
- `Uri` should point to `.../releases/latest/download/neuravpn.appinstaller`
- `MainPackage Uri` should point to `.../releases/latest/download/neuravpn.msix`
- `Version` and `MainPackage Version` must match the MSIX `msix_version`
- `Publisher` must match your MSIX manifest Publisher (and cert subject), e.g. `CN=neuravpn`
- `Name` must match `identity_name` in `pubspec.yaml`

Users install once by opening the `.appinstaller` file. After that, Windows checks for updates automatically.
