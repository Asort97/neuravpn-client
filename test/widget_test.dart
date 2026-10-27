import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:happycat_vpnclient/main.dart';

void main() {
  const testUri =
      'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com#tag';

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'vpn_profiles': '[{"name":"Profile 1","uri":"$testUri"}]',
      'has_added_key': true,
    });
    debugForceMobileShell = true;
  });

  tearDown(() {
    debugForceMobileShell = false;
  });

  testWidgets('app shell renders expected navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VpnApp());
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsNothing);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('Подключение'), findsOneWidget);
    expect(find.text('Проверка'), findsNothing);

    await tester.fling(find.byType(PageView), const Offset(-900, 0), 1800);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.fling(find.byType(PageView), const Offset(-900, 0), 1800);
    await tester.pump(const Duration(milliseconds: 500));
    for (final removed in [
      'Обновления',
      'Проверить',
      'Автоподключение',
      'Режим разработчика',
      'Диагностика',
    ]) {
      expect(find.text(removed, skipOffstage: false), findsNothing);
    }
    expect(find.text('Системный VPN', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Конфигурация VPN core', skipOffstage: false),
      findsNothing,
    );
    expect(
      find.textContaining('Статус VPN', skipOffstage: false),
      findsNothing,
    );

    expect(
      find.text('Агрессивная маскировка', skipOffstage: false),
      findsNothing,
    );
  });

  for (final width in <double>[320, 360, 480]) {
    testWidgets('mobile shell fits ${width.toInt()} px width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const VpnApp());
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.byType(PageView), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(PageView)),
        ).scale(10),
        13,
      );
      expect(tester.takeException(), isNull);
      for (var page = 0; page < 2; page++) {
        await tester.fling(find.byType(PageView), Offset(-width, 0), 1000);
        await tester.pump(const Duration(milliseconds: 800));
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final size in [const Size(760, 360), const Size(320, 568)]) {
    testWidgets('mobile fits $size with keyboard and large text', (
      tester,
    ) async {
      final onError = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint(details.toString());
        onError?.call(details);
      };
      addTearDown(() => FlutterError.onError = onError);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const VpnApp());
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('long press drag selects a connection quick action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const VpnApp());
    await tester.pump(const Duration(milliseconds: 800));

    final button = find.byKey(const ValueKey('main-connect-button'));
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));

    final routingAction = find.byKey(
      const ValueKey('connect-quick-action-routing'),
    );
    expect(routingAction, findsOneWidget);
    await gesture.moveTo(tester.getCenter(routingAction));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    final smartSwitch = tester.widget<Switch>(find.byType(Switch).first);
    expect(smartSwitch.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press released outside cancels the quick action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const VpnApp());
    await tester.pump(const Duration(milliseconds: 800));
    final before = tester.widget<Switch>(find.byType(Switch).first).value;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('main-connect-button'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(const Offset(4, 4));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('connect-quick-action-routing')),
      findsNothing,
    );
    expect(tester.widget<Switch>(find.byType(Switch).first).value, before);
    expect(tester.takeException(), isNull);
  });
}
