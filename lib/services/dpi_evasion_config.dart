enum DpiEvasionProfile { balanced, aggressive }

class DpiEvasionConfig {
  const DpiEvasionConfig._({
    required this.enableFragmentation,
    required this.enableTtlPhantom,
    required this.enableTlsFragment,
    required this.enableTlsRecordFragment,
    required this.enableTrafficNoise,
    required this.enableMultiplexPadding,
    required this.enableTcpWindowClamp,
    required this.enableSniCaseRandomization,
    required this.tlsFragmentFallbackDelay,
    required this.profile,
  });

  final bool enableFragmentation;
  final bool enableTtlPhantom;
  final bool enableTlsFragment;
  final bool enableTlsRecordFragment;
  final bool enableTrafficNoise;
  final bool enableMultiplexPadding;
  final bool enableTcpWindowClamp;
  final bool enableSniCaseRandomization;
  final Duration? tlsFragmentFallbackDelay;
  final DpiEvasionProfile profile;

  static const DpiEvasionConfig balanced = DpiEvasionConfig._(
    enableFragmentation: true,
    enableTtlPhantom: false,
    enableTlsFragment: false,
    enableTlsRecordFragment: false,
    enableTrafficNoise: false,
    enableMultiplexPadding: false,
    enableTcpWindowClamp: false,
    enableSniCaseRandomization: false,
    tlsFragmentFallbackDelay: null,
    profile: DpiEvasionProfile.balanced,
  );

  static const DpiEvasionConfig aggressive = DpiEvasionConfig._(
    enableFragmentation: true,
    enableTtlPhantom: true,
    enableTlsFragment: true,
    enableTlsRecordFragment: false,
    enableTrafficNoise: false,
    enableMultiplexPadding: false,
    enableTcpWindowClamp: false,
    enableSniCaseRandomization: false,
    tlsFragmentFallbackDelay: Duration(milliseconds: 500),
    profile: DpiEvasionProfile.aggressive,
  );

  DpiEvasionConfig copyWith({
    bool? enableFragmentation,
    bool? enableTtlPhantom,
    bool? enableTlsFragment,
    bool? enableTlsRecordFragment,
    bool? enableTrafficNoise,
    bool? enableMultiplexPadding,
    bool? enableTcpWindowClamp,
    bool? enableSniCaseRandomization,
    Duration? tlsFragmentFallbackDelay,
    DpiEvasionProfile? profile,
  }) {
    return DpiEvasionConfig._(
      enableFragmentation: enableFragmentation ?? this.enableFragmentation,
      enableTtlPhantom: enableTtlPhantom ?? this.enableTtlPhantom,
      enableTlsFragment: enableTlsFragment ?? this.enableTlsFragment,
      enableTlsRecordFragment:
          enableTlsRecordFragment ?? this.enableTlsRecordFragment,
      enableTrafficNoise: enableTrafficNoise ?? this.enableTrafficNoise,
      enableMultiplexPadding:
          enableMultiplexPadding ?? this.enableMultiplexPadding,
      enableTcpWindowClamp: enableTcpWindowClamp ?? this.enableTcpWindowClamp,
      enableSniCaseRandomization:
          enableSniCaseRandomization ?? this.enableSniCaseRandomization,
      tlsFragmentFallbackDelay:
          tlsFragmentFallbackDelay ?? this.tlsFragmentFallbackDelay,
      profile: profile ?? this.profile,
    );
  }

  /// Копирует конфиг с изменением фрагментации
  DpiEvasionConfig copyWithFragmentation(bool enabled) {
    return copyWith(enableFragmentation: enabled);
  }
}
