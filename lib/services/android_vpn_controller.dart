import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Bridges Flutter with the native LibboxVpnService via a method channel.
class AndroidVpnController {
  AndroidVpnController();

  static const MethodChannel _channel = MethodChannel('happycat.vpn/native');

  bool get isSupported => Platform.isAndroid;

  Future<bool> prepareVpn() async {
    if (!isSupported) return false;
    final granted = await _channel.invokeMethod<bool>('prepareVpn');
    return granted ?? false;
  }

  Future<void> startVpn(
    String config, {
    List<String>? includePackages,
    List<String>? excludePackages,
  }) async {
    if (!isSupported) return;
    await _channel.invokeMethod('startVpn', {
      'config': config,
      if (includePackages != null && includePackages.isNotEmpty) 'includePackages': includePackages,
      if (excludePackages != null && excludePackages.isNotEmpty) 'excludePackages': excludePackages,
    });
  }

  Future<void> stopVpn() async {
    if (!isSupported) return;
    await _channel.invokeMethod('stopVpn');
  }

  Future<bool> isRunning() async {
    if (!isSupported) return false;
    final running = await _channel.invokeMethod<bool>('getVpnStatus');
    return running ?? false;
  }
}
