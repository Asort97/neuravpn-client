# neuravpn Privacy Policy

Last updated: 2026-01-08

This Privacy Policy explains how **neuravpn** (the “App”) handles information.

## Summary

- The App processes your network traffic **only to provide the VPN/tunneling functionality** you enable.
- The App **does not require an account** and **does not intentionally collect or sell** personal data.
- Connection profiles/keys/subscriptions you add are stored **locally on your device**.

## Data the App processes

### VPN traffic (network data)
When you connect, the App routes your network traffic through the configured tunnel. To do this, the App and its VPN core (e.g., sing-box) may process:
- IP addresses, domain names, ports, and protocol metadata needed to establish and maintain the connection.
- Traffic content needed to transport your requests to the destination (the App does not add application-level tracking).

**We do not intentionally log or transmit the contents of your browsing, messages, or files to the developer.**

### Connection profiles, keys, and subscriptions (user-provided data)
If you import a `vless://` key or a subscription URL, the App stores it locally so you can reconnect later. This can include:
- Server addresses/domains, ports, public keys, SNI/ALPN, and other connection parameters.
- Subscription URLs and downloaded profile lists from those URLs.

This information is stored **on your device**. It is not automatically uploaded to the developer.

### Diagnostics (logs)
The App may display local logs for troubleshooting. If you choose to share logs (for example, by copying them and sending them to support), that sharing is **initiated by you**.

### Update checks
The App may check for updates by contacting a distribution endpoint (for example, Microsoft Store services, or a GitHub Releases endpoint if you use a non-Store build). This request can reveal standard network metadata (e.g., your IP address to the hosting provider) as with any web request.

## Data sharing

The App may communicate with:
- **Your chosen VPN server(s)** to provide connectivity.
- **Subscription providers** when you add/update a subscription URL.
- **Distribution/update providers** (e.g., Microsoft Store, GitHub) to fetch update information (depending on the build and your actions).

The developer does not sell personal data.

## Data retention

- Profiles/keys/subscriptions remain on your device until you delete them from within the App or remove the App.
- Downloaded subscription content is refreshed/overwritten when you update it.

## Security

We aim to keep your data secure, but no method of storage or transmission is 100% secure. You are responsible for keeping your device and imported keys/subscription links safe.

## Children

The App is not intended for children under 13.

## Changes to this policy

We may update this policy from time to time. The “Last updated” date will reflect the latest version.

## Contact

For privacy questions, please open an issue in the project repository:
https://github.com/Asort97/neuravpn-client

