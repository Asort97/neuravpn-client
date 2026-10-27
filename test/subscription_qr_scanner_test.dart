import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/main.dart';
import 'package:happycat_vpnclient/widgets/add_profile_dialog.dart';
import 'package:happycat_vpnclient/widgets/subscription_qr_scanner.dart';
import 'package:happycat_vpnclient/widgets/neura_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCamera extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  final torch = StreamController<TorchState>.broadcast();
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  bool denied = false;
  Completer<void>? starting;

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => torch.stream;
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Color(0xFF303030));
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    await starting?.future;
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> toggleTorch() async {
    torch.add(TorchState.on);
  }

  void scan(String value) => captures.add(
    BarcodeCapture(
      barcodes: [Barcode(rawValue: value, format: BarcodeFormat.qrCode)],
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCamera camera;
  late MobileScannerPlatform original;

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
  setUp(() {
    original = MobileScannerPlatform.instance;
    camera = FakeCamera();
    MobileScannerPlatform.instance = camera;
  });
  tearDown(() async {
    await camera.captures.close();
    await camera.torch.close();
    MobileScannerPlatform.instance = original;
  });

  Future<void> open(
    WidgetTester tester, {
    ValueChanged<String?>? result,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NeuraUi.buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final value = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => const SubscriptionQrScanner(),
                  ),
                );
                result?.call(value);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid QR stays open, valid QR returns only once', (
    tester,
  ) async {
    final values = <String?>[];
    await open(tester, result: values.add);
    camera.scan('not a subscription');
    await tester.pumpAndSettle();
    expect(
      find.text('Этот QR не содержит подписку или ключ VLESS / Hysteria 2'),
      findsOneWidget,
    );
    expect(values, isEmpty);
    camera.scan('https://example.com/sub');
    camera.scan('https://example.com/sub');
    await tester.pumpAndSettle();
    expect(values, ['https://example.com/sub']);
    expect(camera.stops, 1);
    expect(camera.disposals, 1);
  });

  testWidgets('camera stops in background and resumes; torch and cancel work', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Включить фонарик'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Выключить фонарик'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(camera.stops, 1);
    camera.scan('https://example.com/sub');
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionQrScanner), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.starts, 2);
    await tester.tap(find.byTooltip('Закрыть сканер'));
    await tester.pumpAndSettle();
    expect(camera.disposals, 1);
  });

  testWidgets('denied permission can be retried without losing the route', (
    tester,
  ) async {
    camera.denied = true;
    await open(tester);
    expect(find.text('Нет доступа к камере'), findsOneWidget);
    camera.denied = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Нет доступа к камере'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'closing during pending camera start releases camera afterwards',
    (tester) async {
      camera.starting = Completer<void>();
      await tester.pumpWidget(const MaterialApp(home: SubscriptionQrScanner()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      camera.starting!.complete();
      await tester.pumpAndSettle();
      expect(camera.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding during permission prompt stops the late camera', (
    tester,
  ) async {
    camera.starting = Completer<void>();
    await tester.pumpWidget(const MaterialApp(home: SubscriptionQrScanner()));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    camera.starting!.complete();
    await tester.pumpAndSettle();
    expect(camera.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.starts, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final size in [
    const Size(320, 640),
    const Size(480, 800),
    const Size(760, 360),
  ]) {
    testWidgets('scanner fits $size with large text', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(SubscriptionQrScanner),
        matchesGoldenFile(
          'goldens/qr_scanner_${size.width.toInt()}x${size.height.toInt()}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('mobile dialog fills scan result and waits for explicit Add', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddProfileDialog(
            onScanQr: () async => 'https://example.com/sub',
          ),
        ),
      ),
    );
    await tester.tap(find.text('Сканировать QR'));
    await tester.pumpAndSettle();
    expect(find.byType(AddProfileDialog), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'https://example.com/sub'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Добавить'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'cancelled scan preserves typed input; desktop has no QR button',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AddProfileDialog(
              initialInput: 'https://example.com/original',
              onScanQr: () async => null,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Сканировать QR'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'https://example.com/original'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AddProfileDialog())),
      );
      expect(find.text('Сканировать QR'), findsNothing);
    },
  );

  testWidgets('mobile empty state scans into confirmation without importing', (
    tester,
  ) async {
    debugForceMobileShell = true;
    addTearDown(() => debugForceMobileShell = false);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    SharedPreferences.setMockInitialValues({'has_added_key': true});
    await tester.pumpWidget(const VpnApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сканировать QR'));
    await tester.pumpAndSettle();
    camera.scan('https://example.com/review-subscription');
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionQrScanner), findsNothing);
    expect(find.byType(AddProfileDialog), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'https://example.com/review-subscription'),
      findsOneWidget,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Добавьте первое подключение'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
