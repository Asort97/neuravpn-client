import 'dart:async';
import 'dart:io';

class SocksClient {
  SocksClient({
    required this.host,
    required this.port,
  });

  final String host;
  final int port;

  Future<Socket> connect(
    String targetHost,
    int targetPort, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    final reader = _SocketReader(socket);
    socket.add([0x05, 0x01, 0x00]);
    await socket.flush();
    final methodReply = await reader.readBytes(2, timeout);
    if (methodReply.length < 2 || methodReply[1] != 0x00) {
      socket.destroy();
      throw StateError('SOCKS auth failed');
    }

    final hostBytes = targetHost.codeUnits;
    if (hostBytes.length > 255) {
      socket.destroy();
      throw StateError('Host too long');
    }
    final request = <int>[0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes];
    request.add((targetPort >> 8) & 0xFF);
    request.add(targetPort & 0xFF);
    socket.add(request);
    await socket.flush();

    final header = await reader.readBytes(4, timeout);
    if (header.length < 4 || header[1] != 0x00) {
      socket.destroy();
      throw StateError('SOCKS connect failed');
    }
    final addrType = header[3];
    if (addrType == 0x01) {
      await reader.readBytes(4, timeout);
    } else if (addrType == 0x03) {
      final len = await reader.readBytes(1, timeout);
      await reader.readBytes(len.first, timeout);
    } else if (addrType == 0x04) {
      await reader.readBytes(16, timeout);
    }
    await reader.readBytes(2, timeout);
    return socket;
  }

  Future<ProbeResult> probeTls(
    String targetHost,
    int targetPort, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await connect(targetHost, targetPort, timeout: timeout);
      final secure = await SecureSocket.secure(
        socket,
        host: targetHost,
        onBadCertificate: (_) => true,
      ).timeout(timeout);
      await secure.close();
      return ProbeResult(success: true, latency: stopwatch.elapsed, error: null);
    } catch (e) {
      return ProbeResult(success: false, latency: stopwatch.elapsed, error: e.toString());
    }
  }

}

class _SocketReader {
  _SocketReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> readBytes(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('SOCKS timeout');
      }
      final hasNext = await _iterator.moveNext().timeout(remaining);
      if (!hasNext) {
        throw StateError('Socket closed');
      }
      _buffer.addAll(_iterator.current);
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }
}

class ProbeResult {
  ProbeResult({
    required this.success,
    required this.latency,
    required this.error,
  });

  final bool success;
  final Duration latency;
  final String? error;
}
