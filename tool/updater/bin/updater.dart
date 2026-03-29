// neuravpn updater — standalone CLI utility.
//
// Usage:
//   updater.exe --zip <path-to-zip> --target <install-dir> --pid <caller-pid>
//
// 1. Waits for the process with <pid> to terminate.
// 2. Extracts the zip into <target>, overwriting existing files.
//    Handles both flat zips and zips with a single root folder.
// 3. Launches <target>\neuravpn.exe.
// 4. Exits.

import 'dart:io';
import 'package:archive/archive.dart';
import 'package:args/args.dart';

const _exeName = 'neuravpn.exe';
const _maxWaitSeconds = 30;
const _pollInterval = Duration(milliseconds: 500);

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('zip', mandatory: true, help: 'Path to the downloaded zip')
    ..addOption('target', mandatory: true, help: 'Install directory')
    ..addOption('pid', mandatory: true, help: 'PID of the app to wait for');

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  final zipPath = args['zip'] as String;
  final targetDir = args['target'] as String;
  final callerPid = int.tryParse(args['pid'] as String);

  if (callerPid == null) {
    stderr.writeln('Invalid --pid value');
    exit(1);
  }

  // --- 1. Wait for the calling process to exit ---
  stdout.writeln('Waiting for process $callerPid to exit...');
  final waited = await _waitForProcessExit(callerPid);
  if (!waited) {
    stdout.writeln('Process did not exit in time — force-killing...');
    _forceKill(callerPid);
    await Future.delayed(const Duration(seconds: 2));
  }

  // --- 2. Extract the zip ---
  final zipFile = File(zipPath);
  if (!zipFile.existsSync()) {
    stderr.writeln('Zip file not found: $zipPath');
    exit(1);
  }

  stdout.writeln('Extracting update to $targetDir...');
  try {
    _extractZip(zipFile, targetDir);
  } catch (e) {
    stderr.writeln('Extraction failed: $e');
    exit(1);
  }

  // --- 3. Cleanup ---
  try {
    zipFile.deleteSync();
  } catch (_) {}

  // --- 4. Launch updated app ---
  final appExe = '$targetDir\\$_exeName';
  if (!File(appExe).existsSync()) {
    stderr.writeln('$_exeName not found after extraction at $appExe');
    exit(1);
  }

  stdout.writeln('Launching $appExe...');
  await Process.start(appExe, [], mode: ProcessStartMode.detached);

  stdout.writeln('Done.');
  exit(0);
}

/// Polls until the process with [pid] is no longer running.
/// Returns true if exited, false if timeout.
Future<bool> _waitForProcessExit(int pid) async {
  for (var i = 0; i < (_maxWaitSeconds * 1000) ~/ _pollInterval.inMilliseconds; i++) {
    if (!_isProcessRunning(pid)) return true;
    await Future.delayed(_pollInterval);
  }
  return false;
}

bool _isProcessRunning(int pid) {
  try {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      runInShell: true,
    );
    // tasklist outputs a CSV line with the PID if found
    return result.stdout.toString().contains('"$pid"');
  } catch (_) {
    return false;
  }
}

void _forceKill(int pid) {
  try {
    Process.runSync('taskkill', ['/F', '/PID', '$pid'], runInShell: true);
  } catch (_) {}
}

/// Extracts [zipFile] into [targetDir].
/// If the zip contains a single root folder, its contents are flattened
/// so files end up directly in [targetDir].
void _extractZip(File zipFile, String targetDir) {
  final bytes = zipFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  // Detect single root folder: all entries start with the same prefix
  final prefix = _detectSingleRootPrefix(archive);

  for (final entry in archive) {
    var entryName = entry.name.replaceAll('/', '\\');

    // Strip common root folder if detected
    if (prefix.isNotEmpty && entryName.startsWith(prefix)) {
      entryName = entryName.substring(prefix.length);
      if (entryName.isEmpty) continue; // skip the root dir entry itself
    }

    final outPath = '$targetDir\\$entryName';

    if (entry.isFile) {
      final outFile = File(outPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(entry.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

/// Returns the common root prefix (e.g. "Release\") if ALL entries share
/// exactly one top-level directory. Returns empty string otherwise.
String _detectSingleRootPrefix(Archive archive) {
  String? root;
  for (final entry in archive) {
    final name = entry.name.replaceAll('/', '\\');
    final sep = name.indexOf('\\');
    if (sep == -1) {
      // File at root level — no common prefix
      return '';
    }
    final top = name.substring(0, sep + 1);
    if (root == null) {
      root = top;
    } else if (root != top) {
      return '';
    }
  }
  return root ?? '';
}
