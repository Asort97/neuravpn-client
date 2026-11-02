import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class InstallationIdStore {
  InstallationIdStore(Directory directory)
    : _file = File(path.join(directory.path, 'subscription-installation-id'));

  final File _file;
  static final _pending = <String, Future<String>>{};
  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  Future<String> getOrCreate() {
    final key = _file.absolute.path;
    return _pending.putIfAbsent(
      key,
      () => _readOrCreate().whenComplete(() {
        _pending.remove(key);
      }),
    );
  }

  Future<String> _readOrCreate() async {
    await _file.parent.create(recursive: true);
    final handle = await _file.open(mode: FileMode.append);
    try {
      // Also serialize separate Windows processes during elevated handoff.
      await handle.lock(FileLock.blockingExclusive);
      final length = await handle.length();
      if (length > 0) {
        if (length > 64) throw const FormatException('Invalid installation ID');
        await handle.setPosition(0);
        final stored = ascii.decode(await handle.read(length)).trim();
        if (!_uuidPattern.hasMatch(stored)) {
          throw const FormatException('Invalid installation ID');
        }
        return stored;
      }
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      await handle.writeString(id, encoding: ascii);
      // Never send an ID that exists only in memory.
      await handle.flush();
      return id;
    } finally {
      await handle.close();
    }
  }
}

class SubscriptionRequestIdentity {
  SubscriptionRequestIdentity({
    Future<Map<String, dynamic>> Function()? loadDeviceInfo,
    Future<PackageInfo> Function()? loadPackageInfo,
    Future<Directory> Function()? supportDirectory,
  }) : _loadDeviceInfo = loadDeviceInfo ?? _readDeviceInfo,
       _loadPackageInfo = loadPackageInfo ?? PackageInfo.fromPlatform,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static final instance = SubscriptionRequestIdentity();
  static const _channel = MethodChannel('neuravpn/device_info');
  final Future<Map<String, dynamic>> Function() _loadDeviceInfo;
  final Future<PackageInfo> Function() _loadPackageInfo;
  final Future<Directory> Function() _supportDirectory;
  Future<Map<String, String>>? _headers;

  Future<Map<String, String>> headers() =>
      _headers ??= _loadHeaders().catchError((Object error, StackTrace stack) {
        _headers = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<Map<String, String>> _loadHeaders() async {
    final device = await _loadDeviceInfo();
    final info = await _loadPackageInfo();
    final noBackupDirectory = device['noBackupDirectory'] as String?;
    // Android must not restore the same installation ID onto another phone.
    if (Platform.isAndroid &&
        (noBackupDirectory == null || noBackupDirectory.isEmpty)) {
      throw StateError('Installation storage is unavailable');
    }
    final directory = noBackupDirectory?.isNotEmpty == true
        ? Directory(noBackupDirectory!)
        : await _supportDirectory();
    final id = await InstallationIdStore(directory).getOrCreate();
    final os = _headerValue(device['os'] as String? ?? _platformName);
    final model = _headerValue(device['model'] as String? ?? 'Unknown');
    final version = _headerValue(info.version);
    if (version.isEmpty) throw StateError('App version is unavailable');
    return Map.unmodifiable({
      'X-HWID': id,
      'X-Device-OS': os.isEmpty ? _platformName : os,
      'X-Device-Model': model.isEmpty ? 'Unknown' : model,
      'User-Agent':
          'NeuraVPN/$version ($os; build ${_headerValue(info.buildNumber)})',
      'Accept': '*/*',
    });
  }

  static String get _platformName => switch (Platform.operatingSystem) {
    'android' => 'Android',
    'windows' => 'Windows',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => 'Unknown',
  };

  static Future<Map<String, dynamic>> _readDeviceInfo() async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo') ??
          <String, dynamic>{};
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    }
  }

  static String _headerValue(String value) => value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .trim()
      .runes
      .take(256)
      .map((rune) {
        final char = String.fromCharCode(rune);
        return rune <= 126 ? char : Uri.encodeComponent(char);
      })
      .join();
}
