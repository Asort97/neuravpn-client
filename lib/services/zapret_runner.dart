import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

enum ZapretProfile { basic, alt10, alt11 }

enum ZapretMode { off, zapretOnly, vpnPlusZapret }

class ZapretPaths {
  const ZapretPaths({
    required this.exePath,
    required this.binDir,
    required this.listsDir,
  });

  final String exePath;
  final String binDir;
  final String listsDir;
}

class ZapretRunner {
  static const _exeAsset = 'assets/zapret/bin/winws.exe';
  static const _binAssets = [
    'assets/zapret/bin/WinDivert.dll',
    'assets/zapret/bin/WinDivert64.sys',
    'assets/zapret/bin/cygwin1.dll',
    'assets/zapret/bin/quic_initial_www_google_com.bin',
    'assets/zapret/bin/tls_clienthello_4pda_to.bin',
    'assets/zapret/bin/tls_clienthello_max_ru.bin',
    'assets/zapret/bin/tls_clienthello_www_google_com.bin',
  ];
  static const _listAssets = [
    'assets/zapret/lists/list-general.txt',
    'assets/zapret/lists/list-exclude.txt',
    'assets/zapret/lists/ipset-all.txt',
    'assets/zapret/lists/ipset-exclude.txt',
    'assets/zapret/lists/list-google.txt',
  ];

  Process? _process;
  ZapretPaths? _paths;

  bool get isRunning => _process != null;

  Future<ZapretPaths?> ensurePrepared() async {
    if (!Platform.isWindows) return null;

    try {
      final supportDir = await getApplicationSupportDirectory();
      final baseDir = Directory('${supportDir.path}/zapret');
      final binDir = Directory('${baseDir.path}/bin');
      final listsDir = Directory('${baseDir.path}/lists');
      binDir.createSync(recursive: true);
      listsDir.createSync(recursive: true);

      await _copyAsset(_exeAsset, File('${binDir.path}/winws.exe'));
      for (final asset in _binAssets) {
        final target = File('${binDir.path}/${asset.split('/').last}');
        await _copyAsset(asset, target);
      }
      for (final asset in _listAssets) {
        final target = File('${listsDir.path}/${asset.split('/').last}');
        await _copyAsset(asset, target);
      }

      final exe = File('${binDir.path}/winws.exe');
      if (!exe.existsSync()) {
        debugPrint('[ZapretRunner] winws.exe not found after extraction');
        return null;
      }

      _paths = ZapretPaths(
        exePath: exe.path,
        binDir: binDir.path,
        listsDir: listsDir.path,
      );
      return _paths;
    } catch (e, stack) {
      debugPrint('[ZapretRunner] Failed to prepare assets: $e\n$stack');
      return null;
    }
  }

  Future<void> _copyAsset(String asset, File target) async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List();
      var needsWrite = !target.existsSync();
      if (!needsWrite) {
        final currentLength = target.lengthSync();
        if (currentLength != bytes.length) {
          needsWrite = true;
        }
      }
      if (needsWrite) {
        await target.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      debugPrint('[ZapretRunner] Failed to copy $asset -> $target: $e');
    }
  }

  Future<void> stop() async {
    final proc = _process;
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigint);
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return proc.exitCode;
      });
    } catch (_) {
      // ignore
    } finally {
      _process = null;
    }
  }

  Future<bool> start({
    required ZapretProfile profile,
    required bool useGameFilter,
    required List<String> extraIpExcludes,
    required List<String> extraHostExcludes,
  }) async {
    if (isRunning) {
      await stop();
    }
    final paths = await ensurePrepared();
    if (paths == null) return false;

    final args = _buildArgs(
      paths,
      profile: profile,
      useGameFilter: useGameFilter,
      extraIpExcludes: extraIpExcludes,
      extraHostExcludes: extraHostExcludes,
    );
    try {
      _process = await Process.start(
        paths.exePath,
        args,
        runInShell: false,
        workingDirectory: paths.binDir,
      );
      _process?.stdout.transform(utf8.decoder).listen(
            (data) => debugPrint('[zapret] $data'),
            onError: (_) {},
          );
      _process?.stderr.transform(utf8.decoder).listen(
            (data) => debugPrint('[zapret err] $data'),
            onError: (_) {},
          );
      return true;
    } catch (e, stack) {
      debugPrint('[ZapretRunner] Failed to start: $e\n$stack');
      _process = null;
      return false;
    }
  }

  List<String> _buildArgs(
    ZapretPaths paths, {
    required ZapretProfile profile,
    required bool useGameFilter,
    required List<String> extraIpExcludes,
    required List<String> extraHostExcludes,
  }) {
    final listGeneral = '${paths.listsDir}/list-general.txt';
    final listExclude = '${paths.listsDir}/list-exclude.txt';
    final ipsetAll = '${paths.listsDir}/ipset-all.txt';
    final ipsetExclude = '${paths.listsDir}/ipset-exclude.txt';
    final listGoogle = '${paths.listsDir}/list-google.txt';

    final mergedHostExclude = _mergeExtra(listExclude, extraHostExcludes);
    final mergedIpExclude = _mergeExtra(ipsetExclude, extraIpExcludes);

    final gameFilterPorts =
        useGameFilter ? '19294-19344,50000-50100' : '';

    String withGamePorts(String base) {
      return gameFilterPorts.isEmpty ? base : '$base,$gameFilterPorts';
    }

    final args = <String>[
      '--wf-tcp=${withGamePorts("80,443,2053,2083,2087,2096,8443")}',
      '--wf-udp=${withGamePorts("443")}',
    ];

    void addRule(List<String> rule) {
      args.addAll(rule);
      args.add('--new');
    }

    switch (profile) {
      case ZapretProfile.basic:
        addRule([
          '--filter-udp=443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-udp=19294-19344,50000-50100',
          '--filter-l7=discord,stun',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
        ]);
        addRule([
          '--filter-tcp=2053,2083,2087,2096,8443',
          '--hostlist-domains=discord.media',
          '--dpi-desync=multisplit',
          '--dpi-desync-split-seqovl=681',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=443',
          '--hostlist=$listGoogle',
          '--ip-id=zero',
          '--dpi-desync=multisplit',
          '--dpi-desync-split-seqovl=681',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=80,443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=multisplit',
          '--dpi-desync-split-seqovl=568',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_4pda_to.bin',
        ]);
        addRule([
          '--filter-udp=443',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=${withGamePorts("80,443")}',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=multisplit',
          '--dpi-desync-split-seqovl=568',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_4pda_to.bin',
        ]);
        if (gameFilterPorts.isNotEmpty) {

          addRule([
          '--filter-udp=$gameFilterPorts',
          '--ipset=$ipsetAll',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-autottl=2',
          '--dpi-desync-repeats=12',
          '--dpi-desync-any-protocol=1',
          '--dpi-desync-fake-unknown-udp=${paths.binDir}/quic_initial_www_google_com.bin',
          '--dpi-desync-cutoff=n2',
        ]);

        }
        break;
      case ZapretProfile.alt10:
        addRule([
          '--filter-udp=443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-udp=19294-19344,50000-50100',
          '--filter-l7=discord,stun',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
        ]);
        addRule([
          '--filter-tcp=2053,2083,2087,2096,8443',
          '--hostlist-domains=discord.media',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_www_google_com.bin',
          '--dpi-desync-fake-tls-mod=none',
        ]);
        addRule([
          '--filter-tcp=443',
          '--hostlist=$listGoogle',
          '--ip-id=zero',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=80,443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_4pda_to.bin',
        ]);
        addRule([
          '--filter-udp=443',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=${withGamePorts("80,443")}',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_4pda_to.bin',
        ]);
        if (gameFilterPorts.isNotEmpty) {

          addRule([
          '--filter-udp=$gameFilterPorts',
          '--ipset=$ipsetAll',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-autottl=2',
          '--dpi-desync-repeats=12',
          '--dpi-desync-any-protocol=1',
          '--dpi-desync-fake-unknown-udp=${paths.binDir}/quic_initial_www_google_com.bin',
          '--dpi-desync-cutoff=n2',
        ]);

        }
        break;
      case ZapretProfile.alt11:
        addRule([
          '--filter-udp=443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=11',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-udp=19294-19344,50000-50100',
          '--filter-l7=discord,stun',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=6',
        ]);
        addRule([
          '--filter-tcp=2053,2083,2087,2096,8443',
          '--hostlist-domains=discord.media',
          '--dpi-desync=fake,multisplit',
          '--dpi-desync-split-seqovl=681',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-repeats=8',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_www_google_com.bin',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=443',
          '--hostlist=$listGoogle',
          '--ip-id=zero',
          '--dpi-desync=fake,multisplit',
          '--dpi-desync-split-seqovl=681',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-repeats=8',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_www_google_com.bin',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=80,443',
          '--hostlist=$listGeneral',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake,multisplit',
          '--dpi-desync-split-seqovl=654',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-repeats=8',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_max_ru.bin',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_max_ru.bin',
        ]);
        addRule([
          '--filter-udp=443',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-repeats=11',
          '--dpi-desync-fake-quic=${paths.binDir}/quic_initial_www_google_com.bin',
        ]);
        addRule([
          '--filter-tcp=${withGamePorts("80,443")}',
          '--ipset=$ipsetAll',
          '--hostlist-exclude=$mergedHostExclude',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake,multisplit',
          '--dpi-desync-split-seqovl=654',
          '--dpi-desync-split-pos=1',
          '--dpi-desync-fooling=ts',
          '--dpi-desync-repeats=8',
          '--dpi-desync-split-seqovl-pattern=${paths.binDir}/tls_clienthello_max_ru.bin',
          '--dpi-desync-fake-tls=${paths.binDir}/tls_clienthello_max_ru.bin',
        ]);
        if (gameFilterPorts.isNotEmpty) {

          addRule([
          '--filter-udp=$gameFilterPorts',
          '--ipset=$ipsetAll',
          '--ipset-exclude=$mergedIpExclude',
          '--dpi-desync=fake',
          '--dpi-desync-autottl=2',
          '--dpi-desync-repeats=10',
          '--dpi-desync-any-protocol=1',
          '--dpi-desync-fake-unknown-udp=${paths.binDir}/quic_initial_www_google_com.bin',
          '--dpi-desync-cutoff=n2',
        ]);

        }
        break;
    }

    return args;
  }

  String _mergeExtra(String basePath, List<String> extras) {
    try {
      final file = File(basePath);
      final lines = <String>{};
      if (file.existsSync()) {
        final content = file.readAsLinesSync();
        lines.addAll(content.where((e) => e.trim().isNotEmpty));
      }
      lines.addAll(extras.where((e) => e.trim().isNotEmpty));
      final merged = lines.join('\n');
      file.writeAsStringSync('$merged\n');
      return file.path;
    } catch (e) {
      debugPrint('[ZapretRunner] merge failed for $basePath: $e');
      return basePath;
    }
  }

  Future<void> updateListsFromUrls({
    required Uri generalUrl,
    required Uri excludeUrl,
    required Uri ipsetUrl,
    required Uri ipsetExcludeUrl,
  }) async {
    final paths = await ensurePrepared();
    if (paths == null) return;

    Future<void> download(Uri url, String targetName) async {
      try {
        final resp = await http.get(url).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final file = File('${paths.listsDir}/$targetName');
          await file.writeAsBytes(resp.bodyBytes, flush: true);
        }
      } catch (e) {
        debugPrint('[ZapretRunner] Failed to download $url: $e');
      }
    }

    await Future.wait([
      download(generalUrl, 'list-general.txt'),
      download(excludeUrl, 'list-exclude.txt'),
      download(ipsetUrl, 'ipset-all.txt'),
      download(ipsetExcludeUrl, 'ipset-exclude.txt'),
    ]);
  }
}
