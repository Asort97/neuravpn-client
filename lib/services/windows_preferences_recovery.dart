import 'dart:convert';
import 'dart:io';

enum WindowsPreferencesRecoveryAction {
  none,
  normalized,
  restoredBackup,
  reset,
}

class WindowsPreferencesRecoveryResult {
  const WindowsPreferencesRecoveryResult({
    required this.action,
    this.quarantinedPath,
  });

  final WindowsPreferencesRecoveryAction action;
  final String? quarantinedPath;

  bool get changed => action != WindowsPreferencesRecoveryAction.none;
}

class WindowsPreferencesRecovery {
  static const String preferencesFileName = 'shared_preferences.json';
  static const String backupFileName = 'shared_preferences.backup.json';

  static Future<WindowsPreferencesRecoveryResult> recover(
    Directory supportDirectory,
  ) async {
    await supportDirectory.create(recursive: true);

    final primary = File(
      '${supportDirectory.path}${Platform.pathSeparator}$preferencesFileName',
    );
    final backup = File(
      '${supportDirectory.path}${Platform.pathSeparator}$backupFileName',
    );
    final interruptedReplacement = File('${primary.path}.previous');

    final primarySnapshot = await _readSnapshot(primary);
    if (primarySnapshot.isValid) {
      final canonical = primarySnapshot.canonicalJson!;
      var action = WindowsPreferencesRecoveryAction.none;
      if (primarySnapshot.needsNormalization) {
        await _writeAtomically(primary, canonical);
        action = WindowsPreferencesRecoveryAction.normalized;
      }
      await _writeAtomically(backup, canonical);
      await _deleteIfExists(interruptedReplacement);
      return WindowsPreferencesRecoveryResult(action: action);
    }

    String? quarantinedPath;
    if (await primary.exists()) {
      final quarantine = await _nextQuarantineFile(supportDirectory);
      await primary.rename(quarantine.path);
      quarantinedPath = quarantine.path;
    }

    final backupSnapshot = await _readSnapshot(backup);
    final interruptedSnapshot = await _readSnapshot(interruptedReplacement);
    final recoverySnapshot = backupSnapshot.isValid
        ? backupSnapshot
        : interruptedSnapshot;

    if (recoverySnapshot.isValid) {
      final canonical = recoverySnapshot.canonicalJson!;
      await _writeAtomically(primary, canonical);
      await _writeAtomically(backup, canonical);
      await _deleteIfExists(interruptedReplacement);
      return WindowsPreferencesRecoveryResult(
        action: WindowsPreferencesRecoveryAction.restoredBackup,
        quarantinedPath: quarantinedPath,
      );
    }

    await _writeAtomically(primary, '{}');
    await _writeAtomically(backup, '{}');
    await _deleteIfExists(interruptedReplacement);
    return WindowsPreferencesRecoveryResult(
      action: WindowsPreferencesRecoveryAction.reset,
      quarantinedPath: quarantinedPath,
    );
  }

  static Future<_PreferencesSnapshot> _readSnapshot(File file) async {
    if (!await file.exists()) {
      return const _PreferencesSnapshot.invalid();
    }

    try {
      final decodedText = _decodeText(await file.readAsBytes());
      if (decodedText == null || decodedText.text.trim().isEmpty) {
        return const _PreferencesSnapshot.invalid();
      }

      final decoded = jsonDecode(decodedText.text);
      if (decoded is! Map<String, dynamic> ||
          !_containsOnlySupportedValues(decoded)) {
        return const _PreferencesSnapshot.invalid();
      }

      final canonical = jsonEncode(decoded);
      return _PreferencesSnapshot.valid(
        canonical,
        needsNormalization:
            decodedText.nonUtf8Encoding || decodedText.text != canonical,
      );
    } catch (_) {
      return const _PreferencesSnapshot.invalid();
    }
  }

  static _DecodedPreferencesText? _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return null;

    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _DecodedPreferencesText(
        _decodeUtf16(bytes, offset: 2, littleEndian: true),
        nonUtf8Encoding: true,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _DecodedPreferencesText(
        _decodeUtf16(bytes, offset: 2, littleEndian: false),
        nonUtf8Encoding: true,
      );
    }

    final looksLikeUtf16Le =
        bytes.length >= 4 && bytes[1] == 0 && bytes[3] == 0;
    final looksLikeUtf16Be =
        bytes.length >= 4 && bytes[0] == 0 && bytes[2] == 0;
    if (looksLikeUtf16Le || looksLikeUtf16Be) {
      return _DecodedPreferencesText(
        _decodeUtf16(bytes, littleEndian: looksLikeUtf16Le),
        nonUtf8Encoding: true,
      );
    }

    var offset = 0;
    var hadBom = false;
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      offset = 3;
      hadBom = true;
    }
    return _DecodedPreferencesText(
      utf8.decode(bytes.sublist(offset), allowMalformed: false),
      nonUtf8Encoding: hadBom,
    );
  }

  static String _decodeUtf16(
    List<int> bytes, {
    int offset = 0,
    required bool littleEndian,
  }) {
    if ((bytes.length - offset).isOdd) {
      throw const FormatException('Truncated UTF-16 preferences file');
    }

    final codeUnits = <int>[];
    for (var index = offset; index < bytes.length; index += 2) {
      final first = bytes[index];
      final second = bytes[index + 1];
      codeUnits.add(
        littleEndian ? first | (second << 8) : (first << 8) | second,
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static bool _containsOnlySupportedValues(Map<String, dynamic> values) {
    for (final value in values.values) {
      if (value is String || value is bool || value is num) {
        continue;
      }
      if (value is List && value.every((entry) => entry is String)) {
        continue;
      }
      return false;
    }
    return true;
  }

  static Future<void> _writeAtomically(File target, String contents) async {
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final previous = File('${target.path}.previous');

    await temp.writeAsString(contents, encoding: utf8, flush: true);
    await _deleteIfExists(previous);
    if (await target.exists()) {
      await target.rename(previous.path);
    }

    try {
      await temp.rename(target.path);
      await _deleteIfExists(previous);
    } catch (_) {
      await _deleteIfExists(temp);
      if (!await target.exists() && await previous.exists()) {
        await previous.rename(target.path);
      }
      rethrow;
    }
  }

  static Future<File> _nextQuarantineFile(Directory directory) async {
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    var suffix = 0;
    while (true) {
      final suffixText = suffix == 0 ? '' : '-$suffix';
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'shared_preferences.corrupt-$timestamp$suffixText.json',
      );
      if (!await file.exists()) return file;
      suffix++;
    }
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _PreferencesSnapshot {
  const _PreferencesSnapshot.valid(
    this.canonicalJson, {
    required this.needsNormalization,
  }) : isValid = true;

  const _PreferencesSnapshot.invalid()
    : isValid = false,
      canonicalJson = null,
      needsNormalization = false;

  final bool isValid;
  final String? canonicalJson;
  final bool needsNormalization;
}

class _DecodedPreferencesText {
  const _DecodedPreferencesText(this.text, {required this.nonUtf8Encoding});

  final String text;
  final bool nonUtf8Encoding;
}
