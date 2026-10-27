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

import 'profile_availability_test.dart' show PendingCheckBackend;

String keyUri(String name) =>
    'vless://00000000-0000-4000-8000-000000000001@example.com:443#${Uri.encodeComponent(name)}';

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
    testWidgets(
      'HTTPS checks scan hidden rows without selecting them at $width',
      (tester) async {
        final first = keyUri('First server');
        final second = keyUri('Second server');
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
        expect(backend.calls, isEmpty);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Проверить доступность'), findsOneWidget);
        await tester.tap(find.byTooltip('Свернуть'));
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('check-all-profiles'));
        final boundsBefore = tester.getRect(button);
        await tester.tap(button);
        await tester.pump();
        expect(backend.calls, [first]);
        expect(find.text('0/2'), findsOneWidget);
        expect(tester.getRect(button), boundsBefore);
        backend.complete(ProfileAvailability.available);
        await tester.pump();
        expect(backend.calls, [first, second]);
        expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
        backend.complete(ProfileAvailability.unavailable, code: 'TIMEOUT');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Развернуть'));
        await tester.pumpAndSettle();
        expect(
          find.byIcon(Icons.check_circle_outline_rounded),
          findsNWidgets(2),
        );
        expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
        expect(selections, 0);
        expect(tester.takeException(), isNull);
        if (width == 360) {
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(Scaffold),
            matchesGoldenFile('goldens/android_profile_availability.png'),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('stop cancels current scan and does not start another profile', (
    tester,
  ) async {
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
              VpnProfile(name: 'One', uri: keyUri('One')),
              VpnProfile(name: 'Two', uri: keyUri('Two')),
            ],
            selectedProfile: null,
            onProfileSelected: (_) {},
            onDeleteProfile: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-all-profiles')));
    await tester.pump();
    await tester.tap(find.byTooltip('Остановить проверку'));
    await tester.pumpAndSettle();
    expect(backend.cancels, 1);
    expect(backend.calls, hasLength(1));
    expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
