import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class VpnCoreBinaryManager {
  static const String _androidXrayZipAsset =
      'assets/bin/Xray-android-arm64-v8a.zip';
  static const String _androidXrayBinaryName = 'xray';
  static const String _windowsAsset = 'assets/bin/xray.exe';
  static const String _windowsBinaryName = 'xray.exe';

  String? _cachedPath;
  String? _cachedRuntimeKey;

  Future<String?> resolveExecutable({String? androidRuntime}) async {
    final runtimeKey = Platform.isAndroid
        ? 'android:xray'
        : (Platform.isWindows ? 'windows:xray' : 'other:xray');
    if (_cachedRuntimeKey == runtimeKey &&
        _cachedPath != null &&
        File(_cachedPath!).existsSync()) {
      return _cachedPath;
    }

    if (Platform.isAndroid) {
      final local = _searchLocalBinary([
        _androidXrayBinaryName,
        'assets/bin/$_androidXrayBinaryName',
        'assets/bin/xray-android',
      ]);
      if (local != null) {
        _cachedPath = local;
        _cachedRuntimeKey = runtimeKey;
        return local;
      }
      _cachedPath = await _extractAndroidXrayArchive();
      _cachedRuntimeKey = runtimeKey;
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
        _cachedRuntimeKey = runtimeKey;
        return local;
      }
      _cachedPath = await _extractAssetBinary(
        assetPath: _windowsAsset,
        fileName: _windowsBinaryName,
      );
      _cachedRuntimeKey = runtimeKey;
      return _cachedPath;
    }

    final found = _searchLocalBinary(['xray', 'assets/bin/xray']);
    if (found != null) {
      _cachedPath = found;
      _cachedRuntimeKey = runtimeKey;
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

  Future<String?> _extractAndroidXrayArchive() async {
    try {
      final data = await rootBundle.load(_androidXrayZipAsset);
      final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
      final supportDir = await getApplicationSupportDirectory();
      final targetDir = Directory('${supportDir.path}/bin/xray-android');
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }

      String? executablePath;
      for (final entry in archive) {
        final safeName = entry.name.replaceAll('\\', '/');
        if (safeName.isEmpty) continue;
        final targetPath = '${targetDir.path}/$safeName';
        if (entry.isFile) {
          final file = File(targetPath);
          file.parent.createSync(recursive: true);
          final bytes = Uint8List.fromList(entry.content as List<int>);
          await file.writeAsBytes(bytes, flush: true);
          if (safeName == _androidXrayBinaryName) {
            executablePath = file.path;
            await _ensureExecutable(file);
          }
        } else {
          Directory(targetPath).createSync(recursive: true);
        }
      }

      return executablePath;
    } catch (e) {
      debugPrint(
        '[VpnCoreBinaryManager] Unable to extract Android Xray archive: $e',
      );
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
