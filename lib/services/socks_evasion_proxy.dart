import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class SocksEvasionEvent {
  SocksEvasionEvent({
    required this.host,
    required this.port,
    required this.success,
    required this.latency,
    required this.error,
  });

  final String host;
  final int port;
  final bool success;
  final Duration latency;
  final String? error;
}

typedef SocksEvasionCallback = void Function(SocksEvasionEvent event);

class SocksEvasionProxy {
  SocksEvasionProxy({
    this.listenPort = 10811,
    this.aggressive = false,
    this.onEvent,
  });

  final int listenPort;
  final bool aggressive;
  SocksEvasionCallback? onEvent;

  ServerSocket? _server;
  final Set<Socket> _clients = {};

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
      shared: true,
    );
    _server!.listen(_handleClient);
  }

  Future<void> stop() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }

  Future<void> _handleClient(Socket client) async {
    _clients.add(client);
    final reader = _SocketReader(client);
    try {
      final version = await reader.readByte();
      if (version != 0x05) {
        client.destroy();
        return;
      }
      final methodCount = await reader.readByte();
      await reader.readBytes(methodCount);
      client.add([0x05, 0x00]);

      final reqVersion = await reader.readByte();
      if (reqVersion != 0x05) {
        client.destroy();
        return;
      }
      final command = await reader.readByte();
      await reader.readByte(); // reserved
      final addressType = await reader.readByte();

      if (command != 0x01) {
        client.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        client.destroy();
        return;
      }

      String host;
      if (addressType == 0x01) {
        final bytes = await reader.readBytes(4);
        host = bytes.join('.');
      } else if (addressType == 0x03) {
        final length = await reader.readByte();
        final bytes = await reader.readBytes(length);
        host = String.fromCharCodes(bytes);
      } else if (addressType == 0x04) {
        final bytes = await reader.readBytes(16);
        host = InternetAddress.fromRawAddress(Uint8List.fromList(bytes)).address;
      } else {
        client.destroy();
        return;
      }

      final portBytes = await reader.readBytes(2);
      final port = (portBytes[0] << 8) | portBytes[1];

      final stopwatch = Stopwatch()..start();
      Socket? remote;
      try {
        remote = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      } catch (e) {
        client.add([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        onEvent?.call(
          SocksEvasionEvent(
            host: host,
            port: port,
            success: false,
            latency: stopwatch.elapsed,
            error: e.toString(),
          ),
        );
        client.destroy();
        return;
      }

      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      onEvent?.call(
        SocksEvasionEvent(
          host: host,
          port: port,
          success: true,
          latency: stopwatch.elapsed,
          error: null,
        ),
      );

      _pipeWithSplit(client, remote);
      _pipe(remote, client);
    } catch (_) {
      client.destroy();
    }
  }

  void _pipe(Socket source, Socket target) {
    source.listen(
      (data) {
        target.add(data);
      },
      onDone: () {
        target.destroy();
      },
      onError: (_) {
        target.destroy();
      },
      cancelOnError: true,
    );
  }

  void _pipeWithSplit(Socket source, Socket target) {
    var firstChunk = true;
    source.listen(
      (data) async {
        if (!firstChunk) {
          target.add(data);
          return;
        }
        firstChunk = false;
        if (data.isEmpty) return;
        final split = min(data.length, aggressive ? 3 : 1);
        target.add(data.sublist(0, split));
        await Future.delayed(Duration(milliseconds: aggressive ? 15 : 5));
        if (split < data.length) {
          target.add(data.sublist(split));
        }
      },
      onDone: () {
        target.destroy();
      },
      onError: (_) {
        target.destroy();
      },
      cancelOnError: true,
    );
  }
}

class _SocketReader {
  _SocketReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<int> readByte() async {
    final data = await readBytes(1);
    return data.first;
  }

  Future<List<int>> readBytes(int count) async {
    while (_buffer.length < count) {
      final hasNext = await _iterator.moveNext();
      if (!hasNext) {
        throw StateError('Socket closed');
      }
      final next = _iterator.current;
      _buffer.addAll(next);
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }
}
