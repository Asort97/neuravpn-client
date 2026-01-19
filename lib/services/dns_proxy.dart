import 'dart:async';
import 'dart:io';

typedef DnsEventCallback = void Function(DnsEvent event);

typedef DnsResultCallback = void Function(DnsResult event);

class DnsEvent {
  DnsEvent({
    required this.domain,
    required this.timestamp,
  });

  final String domain;
  final DateTime timestamp;
}

class DnsResult {
  DnsResult({
    required this.domain,
    required this.success,
    required this.latency,
  });

  final String domain;
  final bool success;
  final Duration latency;
}

class DnsProxy {
  DnsProxy({
    this.listenPort = 5353,
    InternetAddress? upstreamAddress,
    this.upstreamPort = 53,
    this.onQuery,
    this.onResult,
  }) : _upstreamAddress = upstreamAddress ?? InternetAddress('8.8.8.8');

  final int listenPort;
  final InternetAddress _upstreamAddress;
  final int upstreamPort;
  DnsEventCallback? onQuery;
  DnsResultCallback? onResult;

  RawDatagramSocket? _socket;
  final Map<int, _PendingRequest> _pending = {};

  bool get isRunning => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        listenPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket = socket;
      socket.listen(_handleEvent);
    } catch (e) {
      // Surface binding errors so callers can fallback to remote DNS instead of crashing traffic.
      throw SocketException(
        'Failed to start DNS proxy on 127.0.0.1:$listenPort ($e)',
        address: InternetAddress.loopbackIPv4,
        port: listenPort,
      );
    }
  }

  Future<void> stop() async {
    _pending.clear();
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  void _handleEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;

    final data = datagram.data;
    if (data.length < 12) return;
    final txId = (data[0] << 8) | data[1];

    if (datagram.address == _upstreamAddress && datagram.port == upstreamPort) {
      final pending = _pending.remove(txId);
      if (pending != null) {
        final latency = DateTime.now().difference(pending.timestamp);
        onResult?.call(
          DnsResult(
            domain: pending.domain,
            success: true,
            latency: latency,
          ),
        );
        socket.send(data, pending.client, pending.clientPort);
      }
      return;
    }

    final domain = _parseQueryDomain(data);
    if (domain.isEmpty) return;
    _pending[txId] = _PendingRequest(
      domain: domain,
      timestamp: DateTime.now(),
      client: datagram.address,
      clientPort: datagram.port,
    );
    onQuery?.call(DnsEvent(domain: domain, timestamp: DateTime.now()));
    socket.send(data, _upstreamAddress, upstreamPort);
  }

  String _parseQueryDomain(List<int> data) {
    var offset = 12;
    final labels = <String>[];
    while (offset < data.length) {
      final length = data[offset];
      if (length == 0) {
        offset += 1;
        break;
      }
      if (length & 0xC0 == 0xC0) {
        break;
      }
      if (offset + length >= data.length) return '';
      final label = data.sublist(offset + 1, offset + 1 + length);
      labels.add(String.fromCharCodes(label));
      offset += length + 1;
    }
    return labels.join('.').toLowerCase();
  }
}

class _PendingRequest {
  _PendingRequest({
    required this.domain,
    required this.timestamp,
    required this.client,
    required this.clientPort,
  });

  final String domain;
  final DateTime timestamp;
  final InternetAddress client;
  final int clientPort;
}
