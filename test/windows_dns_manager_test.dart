import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_dns_manager.dart';
import 'package:path/path.dart' as path;

const _uplinkState = <String, dynamic>{
  'Interfaces': <Map<String, dynamic>>[
    <String, dynamic>{
      'InterfaceIndex': 12,
      'InterfaceAlias': 'Ethernet',
      'ServerAddresses': <String>['192.168.0.1'],
    },
  ],
  'Doh': <Map<String, dynamic>>[
    <String, dynamic>{
      'ServerAddress': '9.9.9.9',
      'Existed': true,
      'DohTemplate': 'https://old.example/dns-query',
      'AllowFallbackToUdp': true,
      'AutoUpgrade': false,
    },
    <String, dynamic>{'ServerAddress': '149.112.112.112', 'Existed': false},
  ],
};

const _tunState = <String, dynamic>{
  'InterfaceIndex': 77,
  'InterfaceAlias': 'xray0',
  'ServerAddresses': <String>[],
  'IPAddress': '172.25.10.1',
  'PrefixLength': 30,
};

class _DnsScriptRunner {
  _DnsScriptRunner({
    this.failTunCapture = false,
    this.failRestore = false,
    this.nrptApplied = true,
  });

  final bool failTunCapture;
  final bool failRestore;
  final bool nrptApplied;
  final List<String> scripts = <String>[];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    expect(executable, 'powershell');
    final script = arguments.last;
    scripts.add(script);
    if (script.contains(r'$managedServers')) {
      return ProcessResult(1, 0, jsonEncode(_uplinkState), '');
    }
    if (script.contains(r'$targets = ConvertFrom-Json')) {
      return ProcessResult(
        1,
        0,
        jsonEncode(<String, dynamic>{
          'Success': true,
          'Addresses': <String>['172.25.10.2'],
          'NrptApplied': nrptApplied,
          if (!nrptApplied) 'Warning': 'windows_nrpt_not_supported',
        }),
        '',
      );
    }
    if (script.contains(r'$managedRules = @(') &&
        !script.contains(r'$interfaces = ConvertFrom-Json')) {
      return ProcessResult(1, 0, '{"Success":true}', '');
    }
    if (script.contains(r'$interfaces = ConvertFrom-Json')) {
      if (failRestore) {
        return ProcessResult(
          1,
          0,
          '{"Success":false,"Error":"restore denied"}',
          '',
        );
      }
      return ProcessResult(1, 0, '{"Success":true}', '');
    }
    if (script.contains(r'$httpStatusCode = $null')) {
      return ProcessResult(
        1,
        0,
        '{"Success":true,"SuccessfulQueries":20,'
            '"Addresses":["18.65.1.1"],"HttpStatusCode":200}',
        '',
      );
    }
    if (script.contains(r'$interface = & {')) {
      if (failTunCapture) {
        return ProcessResult(1, 1, '', 'tun capture denied');
      }
      return ProcessResult(1, 0, jsonEncode(_tunState), '');
    }
    return ProcessResult(1, 1, '', 'unexpected PowerShell script');
  }
}

void main() {
  late Directory tempDir;
  late File backupFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('neuravpn_dns_test_');
    backupFile = File(path.join(tempDir.path, 'windows_dns_backup.json'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('prepare stays off the critical path and does not mutate DNS', () async {
    final runner = _DnsScriptRunner();
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );

    final result = await manager.prepare(uplinkInterfaceIndex: 12);

    expect(result.success, isTrue);
    expect(await backupFile.exists(), isFalse);
    expect(runner.scripts, isEmpty);
  });

  test('apply backs up TUN and enables managed DNS routing', () async {
    final runner = _DnsScriptRunner();
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );
    await manager.prepare(uplinkInterfaceIndex: 12);

    final result = await manager.apply(
      uplinkInterfaceIndex: 12,
      tunInterfaceIndex: 77,
    );

    expect(result.success, isTrue);
    final state =
        jsonDecode(await backupFile.readAsString()) as Map<String, dynamic>;
    expect(state['Phase'], 'applied');
    expect(state['Version'], 2);
    expect(
      (state['Interfaces'] as List).map((item) => item['InterfaceIndex']),
      <int>[77],
    );
    final applyScript = runner.scripts.firstWhere(
      (script) => script.contains(r'$targets = ConvertFrom-Json'),
    );
    expect(applyScript, contains('Get-NetIPAddress'));
    expect(applyScript, contains(r'$tunAddress.PrefixLength -ne 30'));
    expect(applyScript, contains(r'$last % 4'));
    expect(applyScript, isNot(contains('9.9.9.9')));
    expect(applyScript, isNot(contains('149.112.112.112')));
    expect(applyScript, isNot(contains('Set-DnsClientDohServerAddress')));
    expect(applyScript, isNot(contains('AllowFallbackToUdp')));
    expect(applyScript, isNot(contains('AutoUpgrade')));
    expect(applyScript, isNot(contains('Clear-DnsClientCache')));
    expect(applyScript, isNot(contains('Resolve-DnsName')));
    expect(applyScript, isNot(contains('Start-Sleep')));
    expect(applyScript, isNot(contains('New-NetRoute')));
    expect(applyScript, isNot(contains("throw 'windows_nrpt_not_supported'")));
    expect(applyScript, contains(r'$nrptApplied = $false'));
    expect(applyScript, contains(r"$warning = 'windows_nrpt_not_supported'"));
    expect(applyScript, contains("Add-DnsClientNrptRule -Namespace '.'"));
    expect(
      applyScript,
      contains(r'-DisplayName $managedRuleName -Comment $managedRuleName'),
    );
    expect(applyScript, contains(r'$_.DisplayName -eq $managedRuleName'));
    expect(applyScript, contains(r'$_.Comment -eq $managedRuleName'));
    expect(applyScript, contains('[77]'));
  });

  test('apply succeeds without NRPT support and reports fallback', () async {
    final runner = _DnsScriptRunner(nrptApplied: false);
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );

    final result = await manager.apply(
      uplinkInterfaceIndex: 12,
      tunInterfaceIndex: 77,
    );

    expect(result.success, isTrue);
    expect(result.logs, contains(contains('priority fallback')));
    expect(result.logs, contains(contains('windows_nrpt_not_supported')));
  });

  test('apply refuses mutation when TUN state cannot be backed up', () async {
    final runner = _DnsScriptRunner(failTunCapture: true);
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );
    await manager.prepare(uplinkInterfaceIndex: 12);

    final result = await manager.apply(
      uplinkInterfaceIndex: 12,
      tunInterfaceIndex: 77,
    );

    expect(result.success, isFalse);
    expect(result.error, contains('dns_tun_backup_failed'));
    expect(await backupFile.exists(), isTrue);
    expect(
      runner.scripts.any(
        (script) => script.contains(r'$targets = ConvertFrom-Json'),
      ),
      isFalse,
    );
  });

  test('restore supports legacy DNS and DoH backup state', () async {
    final runner = _DnsScriptRunner();
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );
    final legacyState = <String, dynamic>{
      ..._uplinkState,
      'Version': 1,
      'ManagedBy': WindowsDnsManager.managedRuleName,
      'Phase': 'applied',
    };
    await backupFile.parent.create(recursive: true);
    await backupFile.writeAsString(jsonEncode(legacyState));

    final result = await manager.restore();

    expect(result.success, isTrue);
    expect(await backupFile.exists(), isFalse);
    final restoreScript = runner.scripts.firstWhere(
      (script) => script.contains(r'$interfaces = ConvertFrom-Json'),
    );
    expect(restoreScript, contains('192.168.0.1'));
    expect(restoreScript, contains('https://old.example/dns-query'));
    expect(restoreScript, contains(r'-AllowFallbackToUdp ([bool]$item.'));
    expect(restoreScript, contains('Remove-DnsClientDohServerAddress'));
    expect(restoreScript, contains('Remove-DnsClientNrptRule'));
    expect(restoreScript, contains(r'$_.DisplayName -eq $managedRuleName'));
    expect(restoreScript, contains(r'$_.Comment -eq $managedRuleName'));
    expect(restoreScript, isNot(contains('Clear-DnsClientCache')));
  });

  test('failed restore keeps backup for next-launch recovery', () async {
    final runner = _DnsScriptRunner(failRestore: true);
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );
    await backupFile.parent.create(recursive: true);
    await backupFile.writeAsString(
      jsonEncode(<String, dynamic>{
        ..._uplinkState,
        'Version': 1,
        'ManagedBy': WindowsDnsManager.managedRuleName,
        'Phase': 'applied',
      }),
    );

    final result = await manager.restore();

    expect(result.success, isFalse);
    expect(result.error, 'restore denied');
    expect(await backupFile.exists(), isTrue);
  });

  test(
    'recover keeps a valid backup after an operational restore failure',
    () async {
      final runner = _DnsScriptRunner(failRestore: true);
      final manager = WindowsDnsManager(
        isWindowsOverride: true,
        backupFile: backupFile,
        processRunner: runner.call,
      );
      await backupFile.parent.create(recursive: true);
      await backupFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ..._uplinkState,
          'Version': 1,
          'ManagedBy': WindowsDnsManager.managedRuleName,
          'Phase': 'applied',
        }),
      );

      final result = await manager.recover();

      expect(result.success, isFalse);
      expect(result.error, 'restore denied');
      expect(await backupFile.exists(), isTrue);
      expect(runner.scripts, hasLength(1));
    },
  );

  test('recover restores a stale managed backup', () async {
    final runner = _DnsScriptRunner();
    final staleState = <String, dynamic>{
      ..._uplinkState,
      'Version': 1,
      'ManagedBy': WindowsDnsManager.managedRuleName,
      'Phase': 'applied',
    };
    await backupFile.parent.create(recursive: true);
    await backupFile.writeAsString(jsonEncode(staleState));
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );

    final result = await manager.recover();

    expect(result.success, isTrue);
    expect(await backupFile.exists(), isFalse);
    expect(result.logs.first, contains('Recovered unfinished'));
  });

  test(
    'recover discards corrupt snapshot after owned policy cleanup',
    () async {
      final runner = _DnsScriptRunner();
      await backupFile.parent.create(recursive: true);
      await backupFile.writeAsString('{broken');
      final manager = WindowsDnsManager(
        isWindowsOverride: true,
        backupFile: backupFile,
        processRunner: runner.call,
      );

      final result = await manager.recover();

      expect(result.success, isTrue);
      expect(await backupFile.exists(), isFalse);
      expect(result.logs, contains(contains('unusable DNS recovery snapshot')));
      expect(
        runner.scripts.any(
          (script) =>
              script.contains(r'$managedRules = @(') &&
              !script.contains(r'$interfaces = ConvertFrom-Json'),
        ),
        isTrue,
      );
    },
  );

  test('test validates 20 DNS queries and CDN HTTP 200', () async {
    final runner = _DnsScriptRunner();
    final manager = WindowsDnsManager(
      isWindowsOverride: true,
      backupFile: backupFile,
      processRunner: runner.call,
    );

    final result = await manager.test();

    expect(result.success, isTrue);
    expect(result.successfulQueries, 20);
    expect(result.addresses, <String>['18.65.1.1']);
    expect(result.httpStatusCode, 200);
    final script = runner.scripts.single;
    expect(script, contains('tr.rbxcdn.com'));
    expect(script, contains(WindowsDnsManager.defaultProbeUrl));
    expect(script, contains(r'Invoke-WebRequest'));
  });
}
