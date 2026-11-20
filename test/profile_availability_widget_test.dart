import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/models/vpn_subscription.dart';
import 'package:happycat_vpnclient/services/profile_availability.dart';
import 'package:happycat_vpnclient/widgets/neura_ui.dart';
import 'package:happycat_vpnclient/widgets/profile_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_availability_test.dart' show PendingCheckBackend, keyUri;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Roboto');
    for (final name in ['Roboto-Regular', 'Roboto-Bold']) {
      font.addFont(
        Future.value(
          ByteData.sublistView(File('test/fonts/$name.ttf').readAsBytesSync()),
        ),
      );
    }
    await font.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [320.0, 360.0, 480.0]) {
    testWidgets('subscription check icon probes only its servers at $width', (
      tester,
    ) async {
      final first = keyUri('First server', host: 'one.example.com');
      final second = keyUri('Second server', host: 'two.example.com');
      final standalone = VpnProfile(name: 'First', uri: first);
      final sub = VpnSubscription(
        id: 's',
        name: 'Subscription',
        url: 'https://example.org/sub',
        profiles: [first, second],
      );
      SharedPreferences.setMockInitialValues({
        'vpn_subscriptions_list': [jsonEncode(sub.toJson())],
      });
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = PendingCheckBackend();
      var selections = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NeuraUi.buildTheme(),
          home: Scaffold(
            body: ProfileListView(
              mobile: true,
              checkBackend: backend,
              profiles: [standalone],
              selectedProfile: standalone,
              onProfileSelected: (_) => selections++,
              onDeleteProfile: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.runs, isEmpty);
      // No global button any more: one small icon per group.
      expect(find.text('Проверить доступность'), findsNothing);
      expect(find.byTooltip('Проверить серверы'), findsNWidgets(2));
      // Collapsing first proves the check opens the subscription itself.
      await tester.tap(find.byTooltip('Свернуть'));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('check-s'));
      await tester.tap(button);
      await tester.pump();
      expect(backend.runs, hasLength(1));
      expect(backend.targets, hasLength(2));
      expect(find.text('Second server'), findsOneWidget);
      expect(find.byTooltip('Остановить проверку'), findsOneWidget);
      // The other group's button waits for this run.
      final local = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('check-__local__')),
          matching: find.byType(IconButton),
        ),
      );
      expect(local.onPressed, isNull);
      backend.answer('t0', ProfileAvailability.available);
      await tester.pump();
      expect(find.textContaining('проверено 1 из 2'), findsOneWidget);
      backend.answer('t1', ProfileAvailability.unavailable, code: 'TIMEOUT');
      backend.finish();
      await tester.pumpAndSettle();
      expect(find.text('120 мс'), findsNWidgets(2));
      expect(find.text('таймаут'), findsOneWidget);
      expect(find.textContaining('работают 1 из 2'), findsOneWidget);
      expect(selections, 0);
      expect(tester.takeException(), isNull);
      if (width == 360) {
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/android_profile_availability.png'),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('stop cancels the running check', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final backend = PendingCheckBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: NeuraUi.buildTheme(),
        home: Scaffold(
          body: ProfileListView(
            mobile: true,
            checkBackend: backend,
            profiles: [
              VpnProfile(
                name: 'One',
                uri: keyUri('One', host: 'a.example.com'),
              ),
              VpnProfile(
                name: 'Two',
                uri: keyUri('Two', host: 'b.example.com'),
              ),
            ],
            selectedProfile: null,
            onProfileSelected: (_) {},
            onDeleteProfile: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-__local__')));
    await tester.pump();
    await tester.tap(find.byTooltip('Остановить проверку'));
    await tester.pumpAndSettle();
    expect(backend.cancels, 1);
    expect(backend.runs, hasLength(1));
    expect(find.byIcon(Icons.speed_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
