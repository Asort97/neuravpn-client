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

class FakePlayUpdates extends AndroidPlayUpdateService {
  final events = StreamController<int>.broadcast();
  final response = Completer<AndroidPlayUpdateStatus>();
  int checks = 0;
  int starts = 0;
  int completes = 0;

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
    return true;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    completes++;
  }
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
  });

  for (final eligible in [false, true]) {
    testWidgets(
      'silent launch check and Play-only update actions eligible=$eligible',
      (tester) async {
        debugForceMobileShell = true;
        SharedPreferences.setMockInitialValues({
          'has_added_key': true,
          'vpn_profiles': VpnProfile.listToJsonString(profiles),
          'vpn_profile_selected_uri': profiles.first.uri,
        });
        messenger.setMockMethodCallHandler(
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
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final updates = FakePlayUpdates();
        final core = FakeVpnCore();
        addTearDown(updates.events.close);
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
        expect(updates.starts, 0);
        expect(tester.takeException(), isNull);
        if (eligible) {
          await tester.tap(find.text('Обновить через Google Play'));
          await tester.pumpAndSettle();
          expect(updates.starts, 1);
          updates.events.add(2);
          await tester.pumpAndSettle();
          expect(find.text('Обновить через Google Play'), findsNothing);
          updates.events.add(11);
          await tester.pumpAndSettle();
          expect(find.text('Завершить обновление'), findsOneWidget);
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
}
