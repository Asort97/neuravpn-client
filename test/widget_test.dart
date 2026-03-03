import 'package:flutter/material.dart';
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
    expect(
      find.text('Конфигурация sing-box', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Developer mode', skipOffstage: false), findsNothing);
    expect(
      find.textContaining('Статус VPN', skipOffstage: false),
      findsNothing,
    );

    expect(
      find.text('Агрессивная маскировка', skipOffstage: false),
      findsNothing,
    );
  });
}
