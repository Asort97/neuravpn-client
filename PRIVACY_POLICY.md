# Privacy Policy for neuravpn

Last updated: March 6, 2026

`neuravpn` is a VPN client application for Windows and Android. This Privacy Policy explains what data the app processes, why it is processed, and what control the user has over that data.

## 1. What the app does

`neuravpn` allows a user to:

- import and store VPN profiles such as `vless://...` links;
- add subscription URLs that return VPN profiles;
- start and stop a VPN connection on the device;
- configure split tunneling rules;
- open the app from `neuravpn://` links for profile or subscription import.

The app is a client tool. The VPN service itself is provided by the server or subscription chosen by the user.

## 2. Data processed by the app

The app may process the following categories of data:

- VPN profile data entered by the user, including VLESS links and related connection parameters;
- subscription URLs entered by the user;
- locally generated VPN configuration files used to start the connection;
- split tunneling rules created by the user;
- on Android, the list of installed applications when the user opens the app picker for split tunneling;
- connection state, basic diagnostics, and local logs needed to operate the VPN client;
- app version information used for update checks on supported platforms.

## 3. How data is used

The app uses the processed data only to provide core functionality, including:

- importing, storing, displaying, and selecting VPN profiles;
- downloading and refreshing subscription content from the URL provided by the user;
- starting, maintaining, and stopping the VPN tunnel;
- applying split tunneling rules selected by the user;
- showing local connection status, diagnostics, and error messages;
- checking for available application updates where supported.

## 4. Data storage

User-provided VPN profiles, subscription URLs, selected profile state, and related settings are stored locally on the device using app-local storage such as shared preferences and app files.

Generated connection configuration files may also be stored locally when required for the selected platform runtime.

## 5. Data sharing and third parties

The app does not sell personal data.

The app does not send user VPN profiles or subscription URLs to the app developer's servers by default.

The app may communicate with third-party endpoints only when required for user-requested functionality, including:

- the VPN server or subscription endpoint chosen by the user;
- GitHub or other release endpoints when the app checks for software updates;
- network destinations reached through the VPN connection or direct connection according to the user's configuration.

Once a VPN connection is established, traffic handling is performed by the selected VPN server or service provider. Their privacy and logging practices are outside the control of `neuravpn`.

## 6. Android app list access

On Android, the app can display installed applications so the user can choose which apps should be included in or excluded from split tunneling rules.

This app list is used only for local rule selection inside the app. It is not sold and is not uploaded to the developer by default.

## 7. Permissions

Depending on platform and version, the app may request permissions or capabilities such as:

- Internet and network state access;
- foreground service and notification permissions for the active VPN session;
- Android `VpnService` capability to create a VPN tunnel;
- package visibility needed to list launchable apps for split tunneling selection.

These permissions are used only to support the VPN client and related features.

## 8. Security

The app is designed to accept only secure VLESS profiles that use TLS or Reality for supported VPN connections.

No software can guarantee absolute security. Users are responsible for protecting their devices, backups, exported configuration data, and the trustworthiness of any VPN server or subscription they choose.

## 9. Data retention and deletion

Most data described in this policy remains on the user's device until the user removes it, clears app data, or uninstalls the app.

Users can delete locally stored profiles and subscriptions from inside the app. Uninstalling the app or clearing app storage removes locally stored app data, subject to platform behavior.

## 10. Children

The app is not directed to children and is not designed for use by children without supervision.

## 11. International transfers

Because the app may connect to VPN servers, subscription endpoints, update servers, or websites chosen by the user, data may be transmitted to countries outside the user's home jurisdiction depending on those services.

## 12. Changes to this policy

This Privacy Policy may be updated from time to time. The latest version should be published with the app distribution materials or the app website.

## 13. Contact

For privacy questions about `neuravpn`, publish and maintain a contact email or support page in your app listing and website before submitting to Google Play.
