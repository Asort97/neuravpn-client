import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:happycat_vpnclient/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final font in ['Roboto-Regular', 'Roboto-Bold']) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(File('test/fonts/$font.ttf').readAsBytesSync()),
        ),
      );
    }
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() {
    debugForceMobileShell = true;
    SharedPreferences.setMockInitialValues({
      'vpn_profiles':
          '[{"name":"Latvia - XHTTP",'
          '"uri":"vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&type=xhttp&sni=example.com#Latvia"}]',
      'has_added_key': true,
    });
  });

  tearDown(() {
    debugForceMobileShell = false;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android three-page layout with safe area', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(const VpnApp());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final context = tester.element(find.byType(Scaffold).first);
      await precacheImage(
        const AssetImage('assets/images/11zon_cropped.png'),
        context,
      );
      await precacheImage(
        const AssetImage('assets/images/anim_connect_mobile/0035.webp'),
        context,
      );
    });
    await tester.pumpAndSettle();

    for (final page in ['connection', 'routing', 'settings']) {
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/android_$page.png'),
      );
      if (page != 'settings') {
        await tester.fling(find.byType(PageView), const Offset(-360, 0), 1000);
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
