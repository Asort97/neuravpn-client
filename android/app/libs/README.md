# Android Xray Runtime

`libXray.aar` is the official XTLS/libXray **v26.7.28** Android artifact,
containing Xray-core **26.7.28**. It uses the versioned JSON `invoke` API;
`AndroidXrayApi` adapts that interface. Do not replace it with the legacy
26.2.6 artifact used by earlier Android builds.

- Release: https://github.com/XTLS/libXray/releases/tag/v26.7.28
- Download: https://github.com/XTLS/libXray/releases/download/v26.7.28/libxray-android.zip
- Archive SHA-256: `28b7dc9d6cc8455fcca5cbd56e387003a7bfb558128651a64899dc3a8ccff666`
- AAR SHA-256: `4708a361a74f7e955635dbe3661cefb459bdc867423c3b1826a2c5a6ea4ac77d`

The archive hash was checked against the GitHub release asset digest before
installation. The source release is MIT-licensed; Xray-core is MPL-2.0.

Device regression evidence (OnePlus Nord 2 / Android 13, 2026-09-05 local):
the same generated Android configuration and REALITY TCP profile failed with
26.2.6, but returned HTTPS 200 with 26.7.28 on the same physical network.
The application with the updated AAR also returned HTTPS 200. No DNS or
subscription credentials were changed for that comparison.

After replacing this AAR, run native tests, verify the embedded version on
an Android device, and recheck all 64-bit ELF LOAD segment alignments before
building the Play upload artifact. Do not update the Windows Xray binary as
part of an Android runtime update.
