# flutter_vless_android

The Android implementation of the `flutter_vless` plugin.

## Runtime

Android runtime binaries and geodata are delivered through the Maven Central AAR dependency `dev.tfox.fluttervless:xray-android:26.9.9-protect1`. This keeps the Pub.dev package lightweight while preserving the same packaged Xray files in the final Android app.

## Emulator Support

The current Maven runtime AAR includes `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`.
This covers both physical Android devices and Android emulators.

## GhostChat app-scoped routing

This local fork is based on `flutter_vless_android` 1.1.6 and retains its MIT
license and upstream notices. GhostChat changes `XrayVPNService.setupVpn()` to
use `VpnService.Builder.addAllowedApplication(packageName)`. The tunnel therefore
captures only GhostChat's application UID; it does not enumerate or capture the
other apps installed on the phone. Upstream `blockedApps` exclusions are not
used by this app-scoped build.
