import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Bridges Flutter with the native Android VPN runtime via a method channel.
class AndroidVpnController {
  AndroidVpnController();

  static const MethodChannel _channel = MethodChannel('happycat.vpn/native');

  bool get isSupported => Platform.isAndroid;

  Future<bool> prepareVpn() async {
    if (!isSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('prepareVpn');
      return granted ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> startVpn(
    String config, {
    String? runtime,
    String? executablePath,
    List<String>? includePackages,
    List<String>? excludePackages,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('startVpn', {
        'config': config,
        if (runtime != null && runtime.isNotEmpty) 'runtime': runtime,
        if (executablePath != null && executablePath.isNotEmpty)
          'executablePath': executablePath,
        if (includePackages != null && includePackages.isNotEmpty)
          'includePackages': includePackages,
        if (excludePackages != null && excludePackages.isNotEmpty)
          'excludePackages': excludePackages,
      });
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  Future<void> stopVpn() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('stopVpn');
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  Future<bool> isRunning() async {
    if (!isSupported) return false;
    try {
      final running = await _channel.invokeMethod<bool>('getVpnStatus');
      return running ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<String> getNativeDebugLog({String? runtime}) async {
    if (!isSupported) return '';
    try {
      final log = await _channel.invokeMethod<String>('getNativeVpnDebugLog', {
        if (runtime != null && runtime.isNotEmpty) 'runtime': runtime,
      });
      return log ?? '';
    } on PlatformException {
      return '';
    }
  }

  Future<void> clearNativeDebugLog({String? runtime}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('clearNativeVpnDebugLog', {
        if (runtime != null && runtime.isNotEmpty) 'runtime': runtime,
      });
    } on PlatformException {
      // Ignore debug log clear failures.
    }
  }

  /// Returns the last startup error written by the VPN service process, or null.
  Future<String?> getLastStartupError() async {
    if (!isSupported) return null;
    try {
      final error =
          await _channel.invokeMethod<String>('getLastStartupError');
      return (error != null && error.isNotEmpty) ? error : null;
    } on PlatformException {
      return null;
    }
  }

  /// Tells the VPN service to re-register its underlying network callback.
  Future<void> refreshNetwork() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('refreshNetwork');
    } on PlatformException {
      // Best-effort; ignore failures.
    }
  }

  /// Returns traffic stats {tx, rx} in bytes from the VPN service, or null.
  Future<({int tx, int rx})?> getTrafficStats() async {
    if (!isSupported) return null;
    try {
      final result =
          await _channel.invokeMethod<Map<Object?, Object?>>('getTrafficStats');
      if (result == null) return null;
      final tx = result['tx'];
      final rx = result['rx'];
      if (tx is int && rx is int) return (tx: tx, rx: rx);
      if (tx is num && rx is num) return (tx: tx.toInt(), rx: rx.toInt());
      return null;
    } on PlatformException {
      return null;
    }
  }
}
