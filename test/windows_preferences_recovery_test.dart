import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_preferences_recovery.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'neuravpn_preferences_recovery_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  File preferencesFile() => File(
    '${tempDirectory.path}${Platform.pathSeparator}'
    '${WindowsPreferencesRecovery.preferencesFileName}',
  );

  File backupFile() => File(
    '${tempDirectory.path}${Platform.pathSeparator}'
    '${WindowsPreferencesRecovery.backupFileName}',
  );

  test('keeps valid preferences and refreshes backup', () async {
    await preferencesFile().writeAsString(
      '{"flutter.has_added_key":true,"flutter.vless_uri":"vless://example"}',
    );

    final result = await WindowsPreferencesRecovery.recover(tempDirectory);

    expect(result.action, WindowsPreferencesRecoveryAction.none);
    expect(result.quarantinedPath, isNull);
    expect(
      jsonDecode(await backupFile().readAsString()),
      jsonDecode(await preferencesFile().readAsString()),
    );
  });

  test('normalizes UTF-16 LE preferences without losing values', () async {
    const source =
        '{"flutter.has_added_key":true,"flutter.profile_counter":12}';
    final bytes = <int>[];
    for (final codeUnit in source.codeUnits) {
      bytes
        ..add(codeUnit & 0xff)
        ..add(codeUnit >> 8);
    }
    await preferencesFile().writeAsBytes(bytes);

    final result = await WindowsPreferencesRecovery.recover(tempDirectory);

    expect(result.action, WindowsPreferencesRecoveryAction.normalized);
    expect(
      jsonDecode(await preferencesFile().readAsString()),
      <String, dynamic>{
        'flutter.has_added_key': true,
        'flutter.profile_counter': 12,
      },
    );
  });

  test('restores malformed preferences from the last valid backup', () async {
    await preferencesFile().writeAsBytes(<int>[0, 0, 0, 0, 0, 0]);
    await backupFile().writeAsString(
      '{"flutter.vless_uri":"vless://restored","flutter.has_added_key":true}',
    );

    final result = await WindowsPreferencesRecovery.recover(tempDirectory);

    expect(result.action, WindowsPreferencesRecoveryAction.restoredBackup);
    expect(result.quarantinedPath, isNotNull);
    expect(File(result.quarantinedPath!).existsSync(), isTrue);
    expect(
      jsonDecode(await preferencesFile().readAsString()),
      <String, dynamic>{
        'flutter.vless_uri': 'vless://restored',
        'flutter.has_added_key': true,
      },
    );
  });

  test(
    'resets storage but preserves malformed file when no backup exists',
    () async {
      await preferencesFile().writeAsString('not-json');

      final result = await WindowsPreferencesRecovery.recover(tempDirectory);

      expect(result.action, WindowsPreferencesRecoveryAction.reset);
      expect(result.quarantinedPath, isNotNull);
      expect(await File(result.quarantinedPath!).readAsString(), 'not-json');
      expect(jsonDecode(await preferencesFile().readAsString()), isEmpty);
      expect(jsonDecode(await backupFile().readAsString()), isEmpty);
    },
  );
}
