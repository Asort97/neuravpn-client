import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class VpnCoreBinaryManager {
  static const String _androidAsset = 'assets/bin/sing-box';
  static const String _androidBinaryName = 'sing-box';
  static const String _windowsAsset = 'assets/bin/xray.exe';
  static const String _windowsBinaryName = 'xray.exe';

  String? _cachedPath;

  Future<String?> resolveExecutable() async {
    if (_cachedPath != null && File(_cachedPath!).existsSync()) {
      return _cachedPath;
    }

    if (Platform.isAndroid) {
      _cachedPath = await _extractAssetBinary(
        assetPath: _androidAsset,
        fileName: _androidBinaryName,
        makeExecutable: true,
      );
      return _cachedPath;
    }

    if (Platform.isWindows) {
      final local = _searchLocalBinary([
        _windowsBinaryName,
        'windows/$_windowsBinaryName',
        'assets/bin/$_windowsBinaryName',
      ]);
      if (local != null) {
        _cachedPath = local;
        return local;
      }
      _cachedPath = await _extractAssetBinary(
        assetPath: _windowsAsset,
        fileName: _windowsBinaryName,
      );
      return _cachedPath;
    }

    final found = _searchLocalBinary(['sing-box', 'assets/bin/sing-box']);
    if (found != null) {
      _cachedPath = found;
      return found;
    }

    return null;
  }

  String? _searchLocalBinary(List<String> candidates) {
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        return file.absolute.path;
      }
    }
    return null;
  }

  Future<String?> _extractAssetBinary({
    required String assetPath,
    required String fileName,
    bool makeExecutable = false,
  }) async {
    try {
      final data = await rootBundle.load(assetPath);
      final supportDir = await getApplicationSupportDirectory();
      final binDir = Directory('${supportDir.path}/bin');
      if (!binDir.existsSync()) {
        binDir.createSync(recursive: true);
      }

      final targetFile = File('${binDir.path}/$fileName');
      final newBytes = data.buffer.asUint8List();
      var needsWrite = !targetFile.existsSync();
      if (!needsWrite) {
        final currentLength = targetFile.lengthSync();
        if (currentLength != newBytes.length) {
          needsWrite = true;
        }
      }

      if (needsWrite) {
        await targetFile.writeAsBytes(newBytes, flush: true);
      }

      if (makeExecutable && !Platform.isWindows) {
        await _ensureExecutable(targetFile);
      }

      return targetFile.path;
    } catch (e) {
      debugPrint('[VpnCoreBinaryManager] Unable to extract $assetPath: $e');
      return null;
    }
  }

  Future<void> _ensureExecutable(File target) async {
    try {
      final stat = await target.stat();
      if ((stat.mode & 0x49) != 0) {
        return;
      }
    } catch (e) {
      debugPrint('[VpnCoreBinaryManager] stat failed: $e');
    }

    await _makeExecutable(target);
  }

  Future<void> _makeExecutable(File target) async {
    const permission = '755';
    final commands = <List<String>>[
      ['/system/bin/chmod', permission, target.path],
      ['chmod', permission, target.path],
      ['/system/bin/toybox', 'chmod', permission, target.path],
      ['/system/bin/sh', '-c', 'chmod $permission ${target.path}'],
    ];

    for (final cmd in commands) {
      final executable = cmd.first;
      final args = cmd.sublist(1);
      try {
        final result = await Process.run(executable, args);
        if (result.exitCode == 0) {
          return;
        }
        debugPrint(
          '[VpnCoreBinaryManager] $executable failed: ${result.stderr}',
        );
      } catch (e) {
        debugPrint('[VpnCoreBinaryManager] $executable exception: $e');
      }
    }

    debugPrint(
      '[VpnCoreBinaryManager] Unable to mark ${target.path} as executable',
    );
  }
}

