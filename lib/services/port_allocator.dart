import 'dart:io';

class PortAllocator {
  /// Try to bind UDP on [preferred], otherwise pick any available port.
  static Future<int> findFreeUdpPort({int? preferred}) async {
    if (preferred != null) {
      final port = await _tryBindUdp(preferred);
      if (port != null) return port;
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      reuseAddress: true,
      reusePort: false,
    );
    final port = socket.port;
    socket.close();
    return port;
  }

  /// Try to bind TCP on [preferred], otherwise pick any available port.
  static Future<int> findFreeTcpPort({int? preferred}) async {
    if (preferred != null) {
      final port = await _tryBindTcp(preferred);
      if (port != null) return port;
    }
    final socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<int?> _tryBindUdp(int port) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        reuseAddress: true,
        reusePort: false,
      );
      socket.close();
      return port;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _tryBindTcp(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      final bound = socket.port;
      await socket.close();
      return bound;
    } catch (_) {
      return null;
    }
  }
}
