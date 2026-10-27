import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/profile_availability.dart';

class PendingCheckBackend extends ProfileCheckBackend {
  final calls = <String>[];
  Completer<ProfileCheckResult>? pending;
  int cancels = 0;
  int releases = 0;
  @override
  Future<void> release() async {
    releases++;
  }

  @override
  Future<ProfileCheckResult> check(String uri) {
    calls.add(uri);
    pending = Completer<ProfileCheckResult>();
    return pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (pending?.isCompleted == false) {
      pending!.complete(const ProfileCheckResult(ProfileAvailability.unknown));
    }
  }

  void complete(ProfileAvailability state, {String? code}) =>
      pending!.complete(ProfileCheckResult(state, elapsedMs: 120, code: code));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'available requires a successful HTTPS response, not a ping or handshake',
    () async {
      const channel = MethodChannel('neuravpn/profile_probe');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final code in [
        null,
        'PING_OK',
        'TCP_OK',
        'TLS_OK',
        'TIMEOUT',
        'HTTPS_FAILED',
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'status': 'available', 'code': code, 'elapsedMs': 42},
        );
        final result = await AndroidProfileCheckBackend().check(
          'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=tcp',
        );
        expect(result.status, ProfileAvailability.error, reason: 'code=$code');
      }
    },
  );
  test(
    'manual, serial, deduplicated checks retain separate URI results',
    () async {
      final backend = PendingCheckBackend();
      final controller = ProfileAvailabilityController(backend)
        ..setProfiles(['a', 'a', 'b']);
      addTearDown(controller.dispose);
      expect(backend.calls, isEmpty);
      final run = controller.checkAll();
      await controller.checkAll();
      expect(backend.calls, ['a']);
      expect(controller.total, 2);
      backend.complete(ProfileAvailability.available);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, ['a', 'b']);
      expect(controller.completed, 1);
      backend.complete(ProfileAvailability.unavailable);
      await run;
      expect(controller.resultFor('a').status, ProfileAvailability.available);
      expect(controller.resultFor('b').status, ProfileAvailability.unavailable);
      expect(controller.running, false);
      expect(backend.releases, 1);
    },
  );

  test(
    'cancel preserves finished results and clears unfinished ones',
    () async {
      final backend = PendingCheckBackend();
      final controller = ProfileAvailabilityController(backend)
        ..setProfiles(['a', 'b', 'c']);
      addTearDown(controller.dispose);
      final run = controller.checkAll();
      backend.complete(ProfileAvailability.available);
      await Future<void>.delayed(Duration.zero);
      await controller.cancel();
      await run;
      expect(backend.calls, ['a', 'b']);
      expect(backend.cancels, 1);
      expect(backend.releases, 1);
      expect(controller.resultFor('a').status, ProfileAvailability.available);
      expect(controller.resultFor('b').status, ProfileAvailability.unknown);
      expect(controller.resultFor('c').status, ProfileAvailability.unknown);
    },
  );

  test(
    'removed configs cannot acquire late green results; observations expire',
    () async {
      var now = DateTime(2026);
      final backend = PendingCheckBackend();
      final controller = ProfileAvailabilityController(backend, now: () => now)
        ..setProfiles(['a', 'b']);
      addTearDown(controller.dispose);
      final run = controller.checkAll();
      controller.setProfiles(['b']);
      backend.complete(ProfileAvailability.available);
      await Future<void>.delayed(Duration.zero);
      backend.complete(ProfileAvailability.available);
      await run;
      expect(controller.resultFor('a').status, ProfileAvailability.unknown);
      now = now.add(const Duration(minutes: 6));
      expect(controller.resultFor('b').status, ProfileAvailability.unknown);
    },
  );

  test(
    'network failure stops scan without declaring remaining servers dead',
    () async {
      final backend = PendingCheckBackend();
      final controller = ProfileAvailabilityController(backend)
        ..setProfiles(['a', 'b']);
      addTearDown(controller.dispose);
      final run = controller.checkAll();
      backend.complete(ProfileAvailability.error, code: 'NO_NETWORK');
      await run;
      expect(backend.calls, ['a']);
      expect(controller.resultFor('a').status, ProfileAvailability.error);
      expect(controller.resultFor('b').status, ProfileAvailability.unknown);
    },
  );

  test(
    'Android checker preserves REALITY and XHTTP, sends no direct outbound',
    () async {
      const channel = MethodChannel('neuravpn/profile_probe');
      Map? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured =
                jsonDecode((call.arguments as Map)['config'] as String) as Map;
            return {'status': 'available', 'elapsedMs': 99, 'code': 'HTTPS_OK'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      for (final type in ['tcp', 'xhttp']) {
        final result = await AndroidProfileCheckBackend().check(
          'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=reality&sni=example.org&pbk=test-key&sid=aa&type=$type&path=%2Fprobe&flow=xtls-rprx-vision',
        );
        expect(result.status, ProfileAvailability.available);
        final outbounds = captured!['outbounds'] as List;
        expect(outbounds, hasLength(1));
        expect(outbounds.single['protocol'], 'vless');
        expect(outbounds.single['streamSettings']['network'], type);
        expect(
          outbounds.single['streamSettings']['realitySettings']['serverName'],
          'example.org',
        );
        expect(captured!.keys, ['outbounds']);
      }
      expect(
        (await AndroidProfileCheckBackend().check('invalid')).code,
        'INVALID_CONFIG',
      );
    },
  );
}
