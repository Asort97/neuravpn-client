import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/main.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/services/android_play_update_service.dart';
import 'package:happycat_vpnclient/widgets/neura_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_switch_test.dart' show FakeVpnCore, profiles;

const offeredUpdate = AndroidPlayUpdateStatus(
  available: true,
  availableVersionCode: 11,
  installStatus: 0,
  flexibleAllowed: true,
  immediateAllowed: true,
  developerTriggeredUpdateInProgress: false,
);

const noUpdate = AndroidPlayUpdateStatus(
  available: false,
  availableVersionCode: 0,
  installStatus: 0,
  flexibleAllowed: false,
  immediateAllowed: false,
  developerTriggeredUpdateInProgress: false,
);

class FakePlayUpdates extends AndroidPlayUpdateService {
  final events = StreamController<int>.broadcast();
  final response = Completer<AndroidPlayUpdateStatus>();
  int checks = 0;
  int starts = 0;
  int completes = 0;
  Object? startError;
  bool startResult = true;

  @override
  Stream<int> get installStatuses => events.stream;
  @override
  Future<AndroidPlayUpdateStatus> check() {
    checks++;
    return response.future;
  }

  @override
  Future<bool> startFlexibleUpdate() async {
    starts++;
    if (startError != null) throw startError!;
    return startResult;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    completes++;
  }
}

Future<FakeVpnCore> pumpUpdateApp(
  WidgetTester tester,
  FakePlayUpdates updates,
) async {
  debugForceMobileShell = true;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({
    'has_added_key': true,
    'vpn_profiles': VpnProfile.listToJsonString(profiles),
    'vpn_profile_selected_uri': profiles.first.uri,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('happycat.vpn/dpi'),
        (_) async => null,
      );
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.5;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  addTearDown(updates.events.close);
  final core = FakeVpnCore();
  await tester.pumpWidget(
    MaterialApp(
      theme: NeuraUi.buildTheme(),
      home: VlessHomePage(
        vpnCoreController: core,
        androidPlayUpdateService: updates,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('happycat.vpn/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('happycat.vpn/dpi'),
      null,
    );
    debugForceMobileShell = false;
  });

  test(
    'launch checks are coalesced and use only the Play native method',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call.method);
        return {
          'available': true,
          'availableVersionCode': 11,
          'installStatus': 0,
          'flexibleAllowed': true,
          'source': 'google_play',
        };
      });
      final service = AndroidPlayUpdateService();
      final first = service.checkAtLaunch();
      expect(identical(first, service.checkAtLaunch()), isTrue);
      expect((await first).canStart, isTrue);
      await service.checkAtLaunch();
      expect(calls, ['checkPlayUpdate']);
    },
  );

  test(
    'ineligible Play installation does not retry or call another updater',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call.method);
        throw PlatformException(code: 'PLAY_UPDATE_UNAVAILABLE');
      });
      final service = AndroidPlayUpdateService();
      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.checkAtLaunch(),
          throwsA(isA<AndroidPlayUpdateException>()),
        );
      }
      expect(calls, ['checkPlayUpdate']);
    },
  );

  test('pending/downloaded updates cannot start a second download', () {
    expect(offeredUpdate.canStart, isTrue);
    for (final status in [1, 2, 3, 4, 11]) {
      expect(offeredUpdate.withInstallStatus(status).canStart, isFalse);
    }
    expect(offeredUpdate.withInstallStatus(11).downloaded, isTrue);
    expect(offeredUpdate.withInstallStatus(6).canStart, isTrue);
    expect(noUpdate.canStart, isFalse);
    expect(
      AndroidPlayUpdateStatus.fromMap({
        'available': true,
        'immediateAllowed': true,
        'flexibleAllowed': false,
      }).canStart,
      isFalse,
    );
  });

  for (final eligible in [false, true]) {
    testWidgets(
      'launch prompt and Play-only update actions eligible=$eligible',
      (tester) async {
        final updates = FakePlayUpdates();
        final core = await pumpUpdateApp(tester, updates);
        expect(updates.checks, 1);
        // The unresolved Play request does not block the app or show a spinner.
        expect(
          find.byKey(const ValueKey('main-connect-button')),
          findsOneWidget,
        );
        expect(core.startedUris, isEmpty);
        for (var page = 0; page < 2; page++) {
          await tester.fling(
            find.byType(PageView),
            const Offset(-320, 0),
            1000,
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('Системный VPN'), findsOneWidget);
        expect(find.text('Проверить'), findsNothing);
        expect(find.text('Обновить через Google Play'), findsNothing);
        if (eligible) {
          updates.response.complete(offeredUpdate);
        } else {
          updates.response.completeError(
            const AndroidPlayUpdateException(
              'PLAY_UPDATE_UNAVAILABLE',
              'Not a Play install',
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(updates.starts, eligible ? 1 : 0);
        expect(tester.takeException(), isNull);
        if (eligible) {
          await tester.tap(find.text('Обновить через Google Play'));
          await tester.pumpAndSettle();
          expect(updates.starts, 2);
          updates.events.add(2);
          await tester.pumpAndSettle();
          expect(find.text('Обновить через Google Play'), findsNothing);
          updates.events.add(11);
          await tester.pumpAndSettle();
          expect(find.text('Завершить обновление'), findsOneWidget);
          await tester.fling(find.byType(SnackBar), const Offset(0, 300), 1000);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Завершить обновление'));
          await tester.pumpAndSettle();
          expect(updates.completes, 1);
        } else {
          expect(find.text('Обновление из Google Play'), findsNothing);
          expect(find.textContaining('Not a Play'), findsNothing);
        }
        expect(updates.checks, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('launch prompt does not wait for settings or block connection', (
    tester,
  ) async {
    final updates = FakePlayUpdates();
    final core = await pumpUpdateApp(tester, updates);
    await tester.tap(find.byKey(const ValueKey('main-connect-button')));
    await tester.pumpAndSettle();
    expect(core.startedUris, [profiles.first.uri]);
    expect(updates.starts, 0);
    updates.response.complete(offeredUpdate);
    await tester.pumpAndSettle();
    expect(updates.starts, 1);
    expect(core.calls, isNot(contains('stop')));
    expect(updates.completes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'background result waits for foreground, cancellation stays quiet',
    (tester) async {
      final updates = FakePlayUpdates()..startResult = false;
      await pumpUpdateApp(tester, updates);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      updates.response.complete(offeredUpdate);
      await tester.pumpAndSettle();
      expect(updates.starts, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(updates.starts, 1);
      updates.events.add(
        6,
      ); // A canceled download must not trigger another prompt.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(updates.starts, 1);
      expect(updates.checks, 1);
      expect(find.textContaining('не смог запустить'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('native foreground race defers without a retry loop', (
    tester,
  ) async {
    final updates = FakePlayUpdates()
      ..startError = const AndroidPlayUpdateException(
        'PLAY_UPDATE_NOT_FOREGROUND',
        'Return to the app to update.',
      );
    updates.response.complete(offeredUpdate);
    await pumpUpdateApp(tester, updates);
    expect(updates.starts, 1);
    updates.startError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(updates.starts, 2);
    expect(updates.checks, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'automatic start failure is silent and is not retried on resume',
    (tester) async {
      final updates = FakePlayUpdates()
        ..startError = const AndroidPlayUpdateException(
          'PLAY_UPDATE_UNAVAILABLE',
          'Play unavailable',
        );
      updates.response.complete(offeredUpdate);
      await pumpUpdateApp(tester, updates);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(updates.starts, 1);
      expect(find.textContaining('Не удалось запустить'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (name, status) in [
    ('unavailable', noUpdate),
    ('downloading', offeredUpdate.withInstallStatus(2)),
  ]) {
    testWidgets('no prompt for $name update', (tester) async {
      final updates = FakePlayUpdates()..response.complete(status);
      await pumpUpdateApp(tester, updates);
      expect(updates.starts, 0);
      expect(updates.completes, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('downloaded update requires explicit install confirmation', (
    tester,
  ) async {
    final updates = FakePlayUpdates()
      ..response.complete(offeredUpdate.withInstallStatus(11));
    await pumpUpdateApp(tester, updates);
    expect(updates.starts, 0);
    expect(updates.completes, 0);
    expect(find.text('Обновить'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();
    expect(updates.completes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('download notice fits 320px with double-size text', (
    tester,
  ) async {
    final updates = FakePlayUpdates()
      ..response.complete(offeredUpdate.withInstallStatus(11));
    await pumpUpdateApp(tester, updates);
    final notice = tester.widget<SnackBar>(find.byType(SnackBar));
    // Isolate the notice from unrelated header layout at extreme text scaling.
    await tester.pumpWidget(const SizedBox.shrink());
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        theme: NeuraUi.buildTheme(),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    messengerKey.currentState!.showSnackBar(notice);
    await tester.pumpAndSettle();
    expect(find.text('Обновить'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('install event wins over a stale launch availability result', (
    tester,
  ) async {
    final updates = FakePlayUpdates();
    await pumpUpdateApp(tester, updates);
    updates.events.add(11);
    await tester.pump();
    updates.response.complete(offeredUpdate);
    await tester.pumpAndSettle();
    expect(updates.starts, 0);
    expect(find.text('Обновить'), findsOneWidget);
    expect(updates.completes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    updates.events.add(11);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(SnackBar), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late result after disposal does not open Play', (tester) async {
    final updates = FakePlayUpdates();
    await pumpUpdateApp(tester, updates);
    await tester.pumpWidget(const SizedBox.shrink());
    updates.response.complete(offeredUpdate);
    await tester.pumpAndSettle();
    expect(updates.starts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new app launch offers the same available version again', (
    tester,
  ) async {
    for (var launch = 0; launch < 2; launch++) {
      final updates = FakePlayUpdates()..response.complete(offeredUpdate);
      await pumpUpdateApp(tester, updates);
      expect(updates.starts, 1);
      expect(updates.checks, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });
}
