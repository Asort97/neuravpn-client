import 'dart:io';
import 'package:flutter/services.dart';

class ProcessSplitController {
  static const _channel = MethodChannel('happycat.vpn/process_split');

  Future<void> start({
    required List<String> applications,
    required bool whitelist,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('startProcessSplit', {
        'mode': whitelist ? 'whitelist' : 'blacklist',
        'apps': applications,
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> update({
    required List<String> applications,
    required bool whitelist,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('updateProcessSplit', {
        'mode': whitelist ? 'whitelist' : 'blacklist',
        'apps': applications,
      });
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('stopProcessSplit');
    } catch (_) {}
  }
}
