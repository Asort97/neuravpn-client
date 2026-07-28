import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/models/vpn_subscription.dart';
import 'package:happycat_vpnclient/widgets/neura_ui.dart';
import 'package:happycat_vpnclient/widgets/profile_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('subscription list uses the compact selected layout', (
    tester,
  ) async {
    final profiles = <String>[
      _vlessUri('Белые списки 1', port: 443, type: 'xhttp'),
      _vlessUri('Белые списки 2', port: 8443, type: 'tcp'),
      _vlessUri('Белые списки 3', port: 2053, type: 'xhttp'),
    ];
    final subscription = VpnSubscription(
      id: 'subscription-1',
      name: 'webhook.staticdeliverycdn.com',
      url: 'https://webhook.staticdeliverycdn.com/merged-sub/test',
      profiles: profiles,
      lastUpdated: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'vpn_subscriptions_list': <String>[jsonEncode(subscription.toJson())],
    });

    await tester.binding.setSurfaceSize(const Size(640, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NeuraUi.buildTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 380,
            child: ProfileListView(
              profiles: const <VpnProfile>[],
              selectedProfile: VpnProfile(
                name: 'Белые списки 1',
                uri: profiles.first,
              ),
              onProfileSelected: (_) {},
              onDeleteProfile: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Текущий выбор'), findsOneWidget);
    expect(find.text('Белые списки'), findsOneWidget);
    expect(find.textContaining('3 сервера'), findsOneWidget);
    expect(find.text('Сменить'), findsNothing);
    expect(find.text('Обновить'), findsNothing);
    expect(find.text('Удалить'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));

    await tester.tap(find.byTooltip('Свернуть'));
    await tester.pumpAndSettle();

    expect(find.text('Белые списки 2'), findsNothing);
    expect(find.text('Белые списки 1'), findsOneWidget);
  });

  testWidgets('mouse wheel movement is animated', (tester) async {
    final controller = NeuraSmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ListView.builder(
            controller: controller,
            itemExtent: 48,
            itemCount: 30,
            itemBuilder: (_, index) => Text('Item $index'),
          ),
        ),
      ),
    );

    tester.binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120));

    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(120, 0.5));
  });
}

String _vlessUri(String name, {required int port, required String type}) {
  return 'vless://d432a14b-3e92-4649-8095-781aaa039caa@'
      'ru.staticdeliverycdn.com:$port?encryption=none&security=reality'
      '&sni=example.com&type=$type#${Uri.encodeComponent(name)}';
}
