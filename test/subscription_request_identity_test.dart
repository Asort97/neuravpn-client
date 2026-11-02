import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/subscription_request_identity.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'support/subscription_identity.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('neura_identity_test_');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('ID is persisted before first use and survives new instances', () async {
    final id = await InstallationIdStore(directory).getOrCreate();
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(
      await File(
        '${directory.path}/subscription-installation-id',
      ).readAsString(),
      id,
    );
    expect(await InstallationIdStore(directory).getOrCreate(), id);
  });

  test('concurrent import and refresh share one persisted ID', () async {
    final ids = await Future.wait(
      List.generate(32, (_) => InstallationIdStore(directory).getOrCreate()),
    );
    expect(ids.toSet(), hasLength(1));
    expect(await InstallationIdStore(directory).getOrCreate(), ids.first);
  });

  test('different installations get different IDs', () async {
    final first = await InstallationIdStore(
      Directory('${directory.path}/a'),
    ).getOrCreate();
    final second = await InstallationIdStore(
      Directory('${directory.path}/b'),
    ).getOrCreate();
    expect(first, isNot(second));
  });

  test('corrupt ID is not silently replaced', () async {
    final file = File('${directory.path}/subscription-installation-id');
    await file.writeAsString('corrupt');
    await expectLater(
      InstallationIdStore(directory).getOrCreate(),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'corrupt');
  });

  test(
    'headers contain app version and preserve ID across app updates',
    () async {
      final identity = testSubscriptionIdentity(directory);
      final first = await identity.headers();
      expect(await identity.headers(), same(first));
      final updated = await testSubscriptionIdentity(
        directory,
        version: '1.0.15',
        buildNumber: '15',
      ).headers();
      expect(updated['X-HWID'], first['X-HWID']);
      expect(updated['X-Device-OS'], 'Windows');
      expect(updated['X-Device-Model'], 'Test PC');
      expect(updated['User-Agent'], 'NeuraVPN/1.0.15 (Windows; build 15)');
    },
  );

  test('Android stores ID outside backup and sends phone model', () async {
    final noBackup = Directory('${directory.path}/no_backup');
    final identity = SubscriptionRequestIdentity(
      loadDeviceInfo: () async => {
        'os': 'Android',
        'model': 'OnePlus Nord 2',
        'noBackupDirectory': noBackup.path,
      },
      loadPackageInfo: () async => PackageInfo(
        appName: 'neuravpn',
        packageName: 'com.neuravpn.app',
        version: '1.0.14',
        buildNumber: '14',
      ),
      supportDirectory: () async =>
          throw StateError('Backup storage must not be used'),
    );
    final headers = await identity.headers();
    expect(headers['X-Device-OS'], 'Android');
    expect(headers['X-Device-Model'], 'OnePlus Nord 2');
    expect(
      await File(
        '${noBackup.path}/subscription-installation-id',
      ).readAsString(),
      headers['X-HWID'],
    );
  });

  test(
    'metadata cannot inject headers and supports non-ASCII model names',
    () async {
      final headers = await testSubscriptionIdentity(
        directory,
        model: 'PC\r\nInjected: value \u0410',
      ).headers();
      expect(headers['X-Device-Model'], 'PC  Injected: value %D0%90');
      expect(
        headers.values.any(
          (value) => value.contains('\r') || value.contains('\n'),
        ),
        isFalse,
      );
    },
  );

  test(
    'storage failure is retryable but never returns an unpersisted ID',
    () async {
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('not a directory');
      final identity = testSubscriptionIdentity(Directory(blocked.path));
      await expectLater(
        identity.headers(),
        throwsA(isA<FileSystemException>()),
      );
      await blocked.delete();
      final headers = await identity.headers();
      expect(
        await File(
          '${blocked.path}/subscription-installation-id',
        ).readAsString(),
        headers['X-HWID'],
      );
    },
  );
}
