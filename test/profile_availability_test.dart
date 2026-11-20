import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/profile_availability.dart';
import 'package:happycat_vpnclient/vless/proxy_parser.dart';

import 'support/xray_subscription.dart';

String keyUri(String name, {String host = 'example.com'}) =>
    'vless://00000000-0000-4000-8000-000000000001@$host:443'
    '?security=tls&sni=$host&type=tcp#${Uri.encodeComponent(name)}';

/// Records each run; the test answers servers one by one.
class PendingCheckBackend extends ProfileCheckBackend {
  final runs = <List<ProfileProbeTarget>>[];
  void Function(ProfileProbeTargetResult)? _sink;
  Completer<ProfileProbeRunResult>? _done;
  int cancels = 0;
  int releases = 0;

  List<ProfileProbeTarget> get targets => runs.last;
  bool get active => _done != null && !_done!.isCompleted;

  @override
  Future<ProfileProbeRunResult> run(
    List<ProfileProbeTarget> targets,
    void Function(ProfileProbeTargetResult result) onResult,
  ) {
    runs.add(targets);
    _sink = onResult;
    _done = Completer<ProfileProbeRunResult>();
    return _done!.future;
  }

  void answer(
    String id,
    ProfileAvailability status, {
    String? code,
    int? elapsedMs,
  }) => _sink!(
    ProfileProbeTargetResult(
      id,
      status,
      code:
          code ??
          (status == ProfileAvailability.available
              ? 'HTTPS_OK'
              : 'HTTPS_FAILED'),
      elapsedMs:
          elapsedMs ?? (status == ProfileAvailability.available ? 120 : null),
    ),
  );

  /// Answers every target of the current run with [status].
  void answerAll(ProfileAvailability status, {String? code}) {
    for (final target in targets) {
      answer(target.id, status, code: code);
    }
  }

  void finish({String? code, bool cancelled = false}) =>
      _done!.complete(ProfileProbeRunResult(code: code, cancelled: cancelled));

  @override
  Future<void> cancel() async {
    cancels++;
    if (active) finish(cancelled: true);
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only an HTTPS response counts as working', () {
    for (final code in [null, 'PING_OK', 'TCP_OK', 'TLS_OK', 'TIMEOUT']) {
      final result = parseAndroidProbeResult({
        'id': 't0',
        'status': 'available',
        'code': code,
        'elapsedMs': 42,
      });
      expect(result.status, ProfileAvailability.error, reason: 'code=$code');
    }
    final ok = parseAndroidProbeResult({
      'id': 't0',
      'status': 'available',
      'code': 'HTTPS_OK',
      'elapsedMs': 42,
    });
    expect(ok.status, ProfileAvailability.available);
    expect(ok.elapsedMs, 42);
    expect(
      parseAndroidProbeResult({
        'id': 't1',
        'status': 'unavailable',
        'code': 'TIMEOUT',
        'elapsedMs': 0,
      }).elapsedMs,
      isNull,
    );
  });

  test('one run probes every server of every requested profile at once', () {
    // A smaller profile repeats the first servers of the auto profile.
    final json = [
      jsonEncode(xraySubscriptionProfile(candidates: 4)),
      jsonEncode(xraySubscriptionProfile(candidates: 2)),
    ];
    // Four VLESS candidates plus the shared Hysteria 2 candidate.
    final auto = (json.first, 5);
    final plan = ProfileProbePlan.build([
      ...json,
      keyUri('Plain'),
      'vless://00000000-0000-4000-8000-000000000001@example.com:443',
      'not a link',
    ]);
    // The auto profile is checked server by server, not by its first outbound.
    expect(plan.targetsByUri[auto.$1], hasLength(auto.$2));
    expect(plan.targets, hasLength(6)); // 5 shared candidates + Plain
    expect(plan.targetsByUri[auto.$1]!.length, greaterThan(1));
    // Servers repeated across profiles are probed once.
    final allIds = plan.targetsByUri.values.expand((ids) => ids).toSet();
    expect(plan.targets.map((t) => t.id).toSet(), allIds);
    expect(
      plan.targets
          .map((t) => jsonEncode({...t.outbound}..remove('tag')))
          .toSet(),
      hasLength(plan.targets.length),
    );
    // Nothing that could go direct is ever sent to the probe.
    expect(
      plan.targets.every(
        (t) => const {
          'vless',
          'vmess',
          'trojan',
          'shadowsocks',
          'hysteria',
        }.contains(t.outbound['protocol']),
      ),
      isTrue,
    );
    // Insecure and broken links are reported, not probed.
    expect(plan.invalid, hasLength(2));
  });

  test('profile results arrive as soon as their servers answer', () async {
    final a = keyUri('A', host: 'a.example.com');
    final b = keyUri('B', host: 'b.example.com');
    final backend = PendingCheckBackend();
    final controller = ProfileAvailabilityController(backend)
      ..setProfiles([a, b]);
    addTearDown(controller.dispose);
    final run = controller.checkAll([a, b], scope: 'sub');
    await controller.checkAll([a]); // A second tap while running is ignored.
    expect(backend.runs, hasLength(1));
    expect(backend.targets, hasLength(2));
    expect(controller.runningScope, 'sub');
    expect(controller.resultFor(a).status, ProfileAvailability.checking);
    backend.answer('t0', ProfileAvailability.available, elapsedMs: 87);
    expect(controller.completed, 1);
    expect(controller.resultFor(a).status, ProfileAvailability.available);
    expect(controller.resultFor(a).elapsedMs, 87);
    expect(controller.resultFor(b).status, ProfileAvailability.checking);
    backend.answer('t1', ProfileAvailability.unavailable, code: 'TIMEOUT');
    backend.finish();
    await run;
    expect(controller.resultFor(b).status, ProfileAvailability.unavailable);
    expect(controller.resultFor(b).isTimeout, isTrue);
    expect(controller.running, isFalse);
    expect(controller.runningScope, isNull);
    expect(backend.releases, 1);
  });

  test(
    'multi-server profile reports how many servers work and the best one',
    () async {
      final auto = jsonEncode(xraySubscriptionProfile(candidates: 5));
      final backend = PendingCheckBackend();
      final controller = ProfileAvailabilityController(backend)
        ..setProfiles([auto]);
      addTearDown(controller.dispose);
      final run = controller.checkAll([auto]);
      final ids = backend.targets.map((t) => t.id).toList();
      backend.answer(ids[0], ProfileAvailability.available, elapsedMs: 300);
      backend.answer(ids[1], ProfileAvailability.available, elapsedMs: 95);
      for (final id in ids.skip(2)) {
        backend.answer(id, ProfileAvailability.unavailable);
      }
      backend.finish();
      await run;
      final result = controller.resultFor(auto);
      expect(result.status, ProfileAvailability.available);
      expect(result.workingServers, 2);
      expect(result.totalServers, ids.length);
      expect(result.elapsedMs, 95);
    },
  );

  test('cancel keeps finished results and clears unfinished ones', () async {
    final uris = [
      for (final n in ['a', 'b', 'c']) keyUri(n, host: '$n.example.com'),
    ];
    final backend = PendingCheckBackend();
    final controller = ProfileAvailabilityController(backend)
      ..setProfiles(uris);
    addTearDown(controller.dispose);
    final run = controller.checkAll(uris);
    backend.answer('t0', ProfileAvailability.available);
    await controller.cancel();
    backend.answer('t1', ProfileAvailability.available); // Late, ignored.
    await run;
    expect(backend.cancels, 1);
    expect(controller.resultFor(uris[0]).status, ProfileAvailability.available);
    expect(controller.resultFor(uris[1]).status, ProfileAvailability.unknown);
    expect(controller.resultFor(uris[2]).status, ProfileAvailability.unknown);
  });

  test('removed configs get no late result; observations expire', () async {
    var now = DateTime(2026);
    final a = keyUri('A', host: 'a.example.com');
    final b = keyUri('B', host: 'b.example.com');
    final backend = PendingCheckBackend();
    final controller = ProfileAvailabilityController(backend, now: () => now)
      ..setProfiles([a, b]);
    addTearDown(controller.dispose);
    final run = controller.checkAll([a, b]);
    controller.setProfiles([b]);
    backend.answerAll(ProfileAvailability.available);
    backend.finish();
    await run;
    expect(controller.resultFor(a).status, ProfileAvailability.unknown);
    expect(controller.resultFor(b).status, ProfileAvailability.available);
    now = now.add(const Duration(minutes: 31));
    expect(controller.resultFor(b).status, ProfileAvailability.unknown);
  });

  test('a broken network never declares servers dead', () async {
    final a = keyUri('A', host: 'a.example.com');
    final b = keyUri('B', host: 'b.example.com');
    final backend = PendingCheckBackend();
    final controller = ProfileAvailabilityController(backend)
      ..setProfiles([a, b]);
    addTearDown(controller.dispose);
    final run = controller.checkAll([a, b]);
    backend.answer('t0', ProfileAvailability.unavailable);
    backend.finish(code: 'NETWORK_CHANGED');
    await run;
    expect(controller.resultFor(a).status, ProfileAvailability.error);
    expect(controller.resultFor(a).code, 'NETWORK_CHANGED');
    expect(controller.resultFor(b).status, ProfileAvailability.error);
  });

  test(
    'Android backend streams results and sends no direct outbound',
    () async {
      const channel = MethodChannel('neuravpn/profile_probe');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      List? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'check') return null;
        final args = call.arguments as Map;
        sent = jsonDecode(args['targets'] as String) as List;
        for (final target in sent!) {
          final reply = const StandardMethodCodec().encodeMethodCall(
            MethodCall('result', {
              'run': args['run'],
              'id': target['id'],
              'status': 'available',
              'code': 'HTTPS_OK',
              'elapsedMs': 64,
            }),
          );
          await messenger.handlePlatformMessage(channel.name, reply, (_) {});
        }
        return {'status': 'done', 'code': ''};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final uri =
          'vless://00000000-0000-4000-8000-000000000001@example.com:443'
          '?security=reality&sni=example.org&pbk=test-key&sid=aa&type=xhttp'
          '&path=%2Fprobe';
      final plan = ProfileProbePlan.build([uri]);
      final results = <ProfileProbeTargetResult>[];
      final outcome = await AndroidProfileCheckBackend().run(
        plan.targets,
        results.add,
      );
      expect(outcome.code, isNull);
      expect(sent, hasLength(1));
      final outbound = sent!.single['outbound'] as Map;
      expect(outbound['protocol'], 'vless');
      expect(outbound['streamSettings']['network'], 'xhttp');
      expect(
        outbound['streamSettings']['realitySettings']['serverName'],
        'example.org',
      );
      expect(results.single.status, ProfileAvailability.available);
      expect(results.single.elapsedMs, 64);
    },
  );
}
