import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/domain_rule_normalizer.dart';
import 'package:public_suffix/public_suffix.dart';

void main() {
  late DomainRuleNormalizer normalizer;

  setUp(() {
    DomainRuleNormalizer.resetForTesting();
    DefaultSuffixRules.initFromString('''
com
ru
uk
co.uk
''');
    normalizer = DomainRuleNormalizer();
  });

  tearDown(() {
    DomainRuleNormalizer.resetForTesting();
  });

  test('whitelist normalizes subdomain to registrable domain', () {
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const ['hd.kinopoisk.ru'],
    );
    expect(result, equals(const ['kinopoisk.ru']));
  });

  test('whitelist strips scheme path query and port before normalization', () {
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const ['https://hd.kinopoisk.ru:8443/watch/1?x=1#top'],
    );
    expect(result, equals(const ['kinopoisk.ru']));
  });

  test('whitelist keeps root domain unchanged', () {
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const ['kinopoisk.ru'],
    );
    expect(result, equals(const ['kinopoisk.ru']));
  });

  test('blacklist normalizes subdomain to registrable domain', () {
    final result = normalizer.normalizeForConnection(
      mode: 'blacklist',
      entries: const ['hd.kinopoisk.ru'],
    );
    expect(result, equals(const ['kinopoisk.ru']));
  });

  test('blacklist sanitizes url input and lifts to base domain', () {
    final result = normalizer.normalizeForConnection(
      mode: 'blacklist',
      entries: const ['https://hd.kinopoisk.ru/path?q=1'],
    );
    expect(result, equals(const ['kinopoisk.ru']));
  });

  test('explicit formats and wildcard stay unchanged', () {
    final input = const [
      'domain-full:hd.kinopoisk.ru',
      'regex:^.*\\.kinopoisk\\.ru\$',
      'geosite:ru',
      '*.kinopoisk.ru',
      'domain:https://hd.kinopoisk.ru/path',
    ];
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: input,
    );
    expect(result, equals(input));
  });

  test('ip and cidr entries stay unchanged', () {
    final input = const [
      '1.2.3.4',
      '2001:db8::1',
      '1.2.3.0/24',
      '2001:db8::/32',
    ];
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: input,
    );
    expect(result, equals(input));
  });

  test('handles public suffixes like co.uk correctly', () {
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const ['a.bbc.co.uk'],
    );
    expect(result, equals(const ['bbc.co.uk']));
  });

  test('falls back to original entry when rules are unavailable', () {
    DomainRuleNormalizer.resetForTesting();
    final debugLogs = <String>[];
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const ['hd.kinopoisk.ru'],
      onDebug: debugLogs.add,
    );

    expect(result, equals(const ['hd.kinopoisk.ru']));
    expect(debugLogs.any((line) => line.contains('psl unavailable')), isTrue);
  });

  test('deduplicates after normalization and keeps first seen order', () {
    final result = normalizer.normalizeForConnection(
      mode: 'whitelist',
      entries: const [
        'a.bbc.co.uk',
        'hd.kinopoisk.ru',
        'kinopoisk.ru',
        'bbc.co.uk',
      ],
    );
    expect(result, equals(const ['bbc.co.uk', 'kinopoisk.ru']));
  });
}
