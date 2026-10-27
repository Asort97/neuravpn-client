import 'package:flutter/services.dart';

class AndroidPlayUpdateStatus {
  const AndroidPlayUpdateStatus({
    required this.available,
    required this.availableVersionCode,
    required this.installStatus,
    required this.flexibleAllowed,
    required this.immediateAllowed,
    required this.developerTriggeredUpdateInProgress,
  });

  factory AndroidPlayUpdateStatus.fromMap(Map<Object?, Object?> value) {
    int asInt(Object? input) => input is num ? input.toInt() : 0;

    return AndroidPlayUpdateStatus(
      available: value['available'] == true,
      availableVersionCode: asInt(value['availableVersionCode']),
      installStatus: asInt(value['installStatus']),
      flexibleAllowed: value['flexibleAllowed'] == true,
      immediateAllowed: value['immediateAllowed'] == true,
      developerTriggeredUpdateInProgress:
          value['developerTriggeredUpdateInProgress'] == true,
    );
  }

  final bool available;
  final int availableVersionCode;
  final int installStatus;
  final bool flexibleAllowed;
  final bool immediateAllowed;
  final bool developerTriggeredUpdateInProgress;

  bool get downloaded => installStatus == 11;
  bool get installing => const {1, 2, 3}.contains(installStatus);
  bool get canStart =>
      available &&
      flexibleAllowed &&
      !downloaded &&
      !installing &&
      installStatus != 4;

  AndroidPlayUpdateStatus withInstallStatus(int status) =>
      AndroidPlayUpdateStatus(
        available: available,
        availableVersionCode: availableVersionCode,
        installStatus: status,
        flexibleAllowed: flexibleAllowed,
        immediateAllowed: immediateAllowed,
        developerTriggeredUpdateInProgress: developerTriggeredUpdateInProgress,
      );
}

class AndroidPlayUpdateException implements Exception {
  const AndroidPlayUpdateException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AndroidPlayUpdateService {
  static const MethodChannel _channel = MethodChannel('happycat.vpn/native');
  static const EventChannel _installEvents = EventChannel(
    'neuravpn/play_update',
  );
  Future<AndroidPlayUpdateStatus>? _launchCheck;

  Stream<int> get installStatuses => _installEvents
      .receiveBroadcastStream()
      .where((event) => event is int)
      .cast<int>();

  // Coalesce launch/resume races. An unavailable Play installation stays silent
  // until the next app launch; there is deliberately no alternate download source.
  Future<AndroidPlayUpdateStatus> checkAtLaunch() => _launchCheck ??= check();

  Future<AndroidPlayUpdateStatus> check() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'checkPlayUpdate',
      );
      if (raw == null) {
        throw const AndroidPlayUpdateException(
          'EMPTY_PLAY_UPDATE_STATUS',
          'Google Play не вернул состояние обновления.',
        );
      }
      return AndroidPlayUpdateStatus.fromMap(raw);
    } on PlatformException catch (error) {
      throw AndroidPlayUpdateException(
        error.code,
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Обновления доступны только для приложения из Google Play.',
      );
    }
  }

  Future<bool> startFlexibleUpdate() async {
    try {
      return await _channel.invokeMethod<bool>('startPlayUpdate') ?? false;
    } on PlatformException catch (error) {
      throw AndroidPlayUpdateException(
        error.code,
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Не удалось запустить обновление через Google Play.',
      );
    }
  }

  Future<void> completeFlexibleUpdate() async {
    try {
      await _channel.invokeMethod<void>('completePlayUpdate');
    } on PlatformException catch (error) {
      throw AndroidPlayUpdateException(
        error.code,
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Не удалось завершить обновление.',
      );
    }
  }
}
