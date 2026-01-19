class LiveTelemetryConfig {
  LiveTelemetryConfig({
    this.dnsPort,
    required this.evasionProxyPort,
    required this.probeVpnPort,
    required this.probeDirectPort,
    required this.probeEvasionPort,
  });

  final int? dnsPort;
  final int evasionProxyPort;
  final int probeVpnPort;
  final int probeDirectPort;
  final int probeEvasionPort;
}
