import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/widgets/neura_motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NeuraSpringCurve', () {
    for (final bounce in <double>[0, 0.18, 0.32]) {
      test(
        'settles before the end without a visible snap (bounce $bounce)',
        () {
          final curve = NeuraSpringCurve(bounce: bounce);
          expect(curve.transform(0), 0);
          expect(curve.transform(1), 1);
          // Just before the end the spring is already within 1% of rest.
          expect((curve.transform(0.999) - 1).abs(), lessThan(0.01));
        },
      );
    }

    test('bouncy spring overshoots, smooth spring does not', () {
      final samples = List<double>.generate(200, (i) => i / 199);
      final bouncyMax = samples
          .map(const NeuraSpringCurve(bounce: 0.32).transform)
          .reduce((a, b) => a > b ? a : b);
      final smoothMax = samples
          .map(const NeuraSpringCurve().transform)
          .reduce((a, b) => a > b ? a : b);
      expect(bouncyMax, greaterThan(1.02));
      expect(smoothMax, lessThanOrEqualTo(1.0));
    });
  });

  group('NeuraHaptics', () {
    final calls = <MethodCall>[];
    final platformCalls = <MethodCall>[];

    setUp(() {
      calls.clear();
      platformCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      NeuraHaptics.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('neuravpn/haptics'),
            null,
          );
    });

    test('iOS uses native notification generator for success', () async {
      NeuraHaptics.debugPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('neuravpn/haptics'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      NeuraHaptics.success();
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'notification');
      expect(calls.single.arguments, {'type': 'success'});
      expect(platformCalls, isEmpty);
    });

    test('Android uses the native haptics channel', () async {
      NeuraHaptics.debugPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('neuravpn/haptics'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      NeuraHaptics.play(NeuraHaptic.rigid);
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'impact');
      expect(calls.single.arguments, {'style': 'rigid'});
      expect(platformCalls, isEmpty);
    });

    test('Android falls back to HapticFeedback without the channel', () async {
      NeuraHaptics.debugPlatformOverride = TargetPlatform.android;
      NeuraHaptics.selection();
      await pumpEventQueue();
      expect(platformCalls.single.method, 'HapticFeedback.vibrate');
    });

    test('desktop is silent', () async {
      NeuraHaptics.debugPlatformOverride = TargetPlatform.windows;
      NeuraHaptics.error();
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, isEmpty);
    });
  });

  testWidgets('NeuraPressable sinks under the finger and springs back', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: NeuraPressable(
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 40),
          ),
        ),
      ),
    );

    double scale() =>
        tester.widget<Transform>(find.byType(Transform)).transform.storage[0];

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(NeuraPressable)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(scale(), closeTo(0.96, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), closeTo(1.0, 0.001));
    expect(taps, 1);
  });
}
