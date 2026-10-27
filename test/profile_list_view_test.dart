import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/models/vpn_subscription.dart';
import 'package:happycat_vpnclient/services/subscription_repository.dart';
import 'package:happycat_vpnclient/widgets/neura_ui.dart';
import 'package:happycat_vpnclient/widgets/profile_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile subscriptions have no search and can be renamed', (
    tester,
  ) async {
    final subscription = VpnSubscription(
      id: 'mobile-sub',
      name: 'My subscription',
      url: 'https://example.com/sub',
      profiles: [
        _vlessUri('Latvia', port: 443, type: 'xhttp'),
        _vlessUri('Germany', port: 8443, type: 'tcp'),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'vpn_subscriptions_list': [jsonEncode(subscription.toJson())],
    });
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: NeuraUi.buildTheme(),
        home: Scaffold(
          body: ProfileListView(
            mobile: true,
            profiles: const [],
            selectedProfile: null,
            onProfileSelected: (_) {},
            onDeleteProfile: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-search')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'Latvia',
      ),
      findsOneWidget,
    );
    expect(find.text('Germany'), findsOneWidget);
    await tester.tap(find.byTooltip('Действия с подпиской'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переименовать'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).last, 'Personal VPN');
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final saved = await SubscriptionRepository().getAllSubscriptions();
    expect(saved.single.name, 'Personal VPN');
    expect(saved.single.profiles, subscription.profiles);
    expect(find.byKey(const ValueKey('profile-search')), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
