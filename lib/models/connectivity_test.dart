import 'dart:convert';

class ConnectivityTestTarget {
  const ConnectivityTestTarget({required this.domain, required this.category});

  final String domain;
  final String category;
}

class ConnectivityTestResult {
  ConnectivityTestResult({
    required this.domain,
    required this.status,
    this.error,
    this.durationMs,
    required this.route,
    required this.timestamp,
    this.httpStatus,
  });

  final String domain;
  final String status;
  final String route;
  final DateTime timestamp;
  final String? error;
  final int? durationMs;
  final int? httpStatus;

  Map<String, dynamic> toJson() => {
    'domain': domain,
    'status': status,
    'route': route,
    if (durationMs != null) 'time_ms': durationMs,
    if (httpStatus != null) 'http_status': httpStatus,
    if (error != null) 'error': error,
    'timestamp': timestamp.toIso8601String(),
  };

  @override
  String toString() => jsonEncode(toJson());
}
