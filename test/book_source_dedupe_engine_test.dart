import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_engine.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';
import 'package:xxread/book_sources/dedupe/book_source_identity.dart';
import 'package:xxread/book_sources/dedupe/book_source_quality_score.dart';

void main() {
  group('BookSourceIdentity', () {
    test(
      'normalizes HTTP casing, default ports, roots, and trailing slashes',
      () {
        expect(
          BookSourceIdentity.parse('https://EXAMPLE.com:443/').canonicalKey,
          'https://example.com',
        );
        expect(
          BookSourceIdentity.parse('http://EXAMPLE.com:80/books/').canonicalKey,
          'http://example.com/books',
        );
        expect(
          BookSourceIdentity.parse('https://example.com:8443/').canonicalKey,
          'https://example.com:8443',
        );
      },
    );

    test('sorts query entries and strips known tracking parameters', () {
      final left = BookSourceIdentity.parse(
        'https://example.com/books?b=2&utm_source=news&a=&a=1&fbclid=x',
      );
      final right = BookSourceIdentity.parse(
        'https://EXAMPLE.com/books?a=1&b=2&a=',
      );

      expect(left.canonicalKey, right.canonicalKey);
      expect(left.canonicalKey, 'https://example.com/books?a=&a=1&b=2');
    });

    test('preserves fragment identity tags including unicode and emoji', () {
      final plain = BookSourceIdentity.parse('https://example.com');
      final simplified = BookSourceIdentity.parse('https://example.com#简体📚');
      final revised = BookSourceIdentity.parse('https://example.com#大改');

      expect(simplified.canonicalKey, isNot(plain.canonicalKey));
      expect(simplified.canonicalKey, isNot(revised.canonicalKey));
      expect(simplified.siteKey, plain.siteKey);
    });

    test('preserves encoded path identity and repeated query values', () {
      final identity = BookSourceIdentity.parse(
        'https://example.com/a%2Fb?tag=x&tag=x&empty=',
      );

      expect(identity.canonicalKey, contains('/a%2Fb'));
      expect(identity.canonicalKey, endsWith('?empty=&tag=x&tag=x'));
    });

    test('formats IPv6 and removes its default port', () {
      final identity = BookSourceIdentity.parse('https://[2001:db8::1]:443/');

      expect(identity.canonicalKey, 'https://[2001:db8::1]');
      expect(identity.siteKey, '[2001:db8::1]');
    });

    test('site identity contains only host and non-default port', () {
      final identity = BookSourceIdentity.parse(
        'https://user:password@example.com:8443/books',
      );

      expect(identity.siteKey, 'example.com:8443');
    });

    test(
      'uses exact-only opaque fallback for non-http and malformed values',
      () {
        for (final value in [
          ' App Source ',
          'ftp://example.com/books',
          '://bad',
        ]) {
          final identity = BookSourceIdentity.parse(value);
          expect(identity.kind, BookSourceIdentityKind.opaque);
          expect(identity.canonicalKey, value.trim());
          expect(identity.siteKey, value.trim());
        }
      },
    );

    test('does not throw for malformed query escaping', () {
      expect(
        () => BookSourceIdentity.parse('https://example.com/?bad=%ZZ'),
        returnsNormally,
      );
    });
  });

  group('BookSourceDedupeEngine', () {
    const engine = BookSourceDedupeEngine();

    test('exact mode only groups trimmed identical identities', () {
      final result = engine.analyze([
        candidate(0, ' https://example.com/ '),
        candidate(1, 'https://example.com/'),
        candidate(2, 'https://EXAMPLE.com'),
      ], mode: BookSourceDedupeMode.exact);

      expect(result.groups, hasLength(1));
      expect(result.groups.single.confidence, BookSourceDedupeConfidence.exact);
      expect(result.groups.single.candidates.map((item) => item.index), [0, 1]);
      expect(result.defaultSelectedIndices, {1, 2});
    });

    test(
      'standard mode groups canonical URLs and selects the best candidate',
      () {
        final result = engine.analyze([
          candidate(
            0,
            'https://EXAMPLE.com:443/?b=2&utm_source=x&a=1',
            extra: {'enabled': false, 'lastUpdateTime': 100},
          ),
          candidate(
            1,
            'https://example.com?a=1&b=2',
            extra: {
              'lastUpdateTime': 200,
              'ruleSearch': {'bookList': '.book'},
              'ruleBookInfo': {'name': 'h1'},
            },
          ),
          candidate(2, 'https://other.example'),
        ]);

        expect(result.groups, hasLength(1));
        expect(
          result.groups.single.confidence,
          BookSourceDedupeConfidence.canonical,
        );
        expect(result.groups.single.recommendedIndex, 1);
        expect(result.groups.single.defaultSelectedIndices, {1});
        expect(result.defaultSelectedIndices, {1, 2});
        expect(result.duplicateCandidateCount, 1);
      },
    );

    test('standard mode keeps paths and identity tags separate', () {
      final result = engine.analyze([
        candidate(0, 'https://example.com/a'),
        candidate(1, 'https://example.com/b'),
        candidate(2, 'https://example.com/a#简体'),
      ]);

      expect(result.groups, isEmpty);
      expect(result.defaultSelectedIndices, {0, 1, 2});
    });

    test('site review groups by host and non-default port and retains all', () {
      final result = engine.analyze([
        candidate(0, 'http://example.com/a#简体'),
        candidate(1, 'https://EXAMPLE.com/b?x=1'),
        candidate(2, 'https://example.com:8443/b'),
      ], mode: BookSourceDedupeMode.siteReview);

      expect(result.groups, hasLength(1));
      expect(
        result.groups.single.confidence,
        BookSourceDedupeConfidence.sameSite,
      );
      expect(result.groups.single.defaultSelectedIndices, {0, 1});
      expect(result.defaultSelectedIndices, {0, 1, 2});
      expect(result.groups.single.requiresReview, isTrue);
    });

    test('site review auto-selects exact duplicate winner', () {
      final result = engine.analyze([
        candidate(0, 'https://example.com'),
        candidate(1, 'https://example.com'),
      ], mode: BookSourceDedupeMode.siteReview);

      expect(result.groups.single.confidence, BookSourceDedupeConfidence.exact);
      expect(result.groups.single.defaultSelectedIndices, {1});
      expect(result.defaultSelectedIndices, {1});
    });

    test('opaque identities remain exact-only in site review', () {
      final result = engine.analyze([
        candidate(0, 'App Source'),
        candidate(1, 'App Source'),
        candidate(2, 'app source'),
      ], mode: BookSourceDedupeMode.siteReview);

      expect(result.groups, hasLength(1));
      expect(result.groups.single.candidates.map((item) => item.index), [0, 1]);
      expect(result.defaultSelectedIndices, {1, 2});
    });

    test('cross-protocol identity conflicts retain all candidates', () {
      final result = engine.analyze([
        candidate(0, 'https://example.com', protocol: 'reading'),
        candidate(1, 'https://example.com', protocol: 'orsp'),
      ]);

      expect(
        result.groups.single.confidence,
        BookSourceDedupeConfidence.conflict,
      );
      expect(result.groups.single.defaultSelectedIndices, {0, 1});
      expect(result.defaultSelectedIndices, {0, 1});
    });

    test(
      'quality ordering prioritizes references, health, and capabilities',
      () {
        final referenced = candidate(
          0,
          'https://example.com',
          installedSourceId: 'installed',
          isReferenced: true,
        );
        final healthy = candidate(1, 'https://example.com', isHealthy: true);
        final capable = candidate(
          2,
          'https://example.com',
          runnableCapabilities: 10,
          compatibilityRank: 10,
        );
        final result = engine.analyze([capable, healthy, referenced]);

        expect(result.groups.single.recommendedIndex, 0);
      },
    );

    test('quality ties prefer installed then the later import entry', () {
      final installedResult = engine.analyze([
        candidate(0, 'https://example.com'),
        candidate(2, 'https://example.com', installedSourceId: 'source-id'),
      ]);
      final inputOrderResult = engine.analyze([
        candidate(7, 'https://other.example'),
        candidate(3, 'https://other.example'),
      ]);

      expect(installedResult.groups.single.recommendedIndex, 2);
      expect(inputOrderResult.groups.single.recommendedIndex, 7);
    });

    test(
      'preserves raw config and provenance without source_config dependency',
      () {
        final raw = <String, dynamic>{
          'bookSourceName': 'Original',
          'bookSourceUrl': 'https://example.com',
          'ruleSearch': <String, dynamic>{'name': 'h1'},
        };
        final item = BookSourceDedupeCandidate(
          index: 4,
          rawConfig: raw,
          provenance: const {'url': 'https://list.example/sources.json'},
        );
        raw['bookSourceName'] = 'Mutated';

        expect(item.name, 'Original');
        expect(item.provenance, {'url': 'https://list.example/sources.json'});
        expect(() => item.rawConfig['x'] = 1, throwsUnsupportedError);
        expect(
          () => (item.rawConfig['ruleSearch'] as Map)['name'] = 'changed',
          throwsUnsupportedError,
        );
      },
    );

    test('analyzes ten thousand candidates without quadratic grouping', () {
      final stopwatch = Stopwatch()..start();
      final result = engine.analyze([
        for (var index = 0; index < 10000; index++)
          candidate(index, 'https://source-${index ~/ 2}.example'),
      ]);
      stopwatch.stop();

      expect(result.groups, hasLength(5000));
      expect(result.defaultSelectedIndices, hasLength(5000));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  test('quality score exposes deterministic winner reasons', () {
    final low = BookSourceQualityScore.fromCandidate(
      candidate(0, 'https://example.com', extra: {'enabled': false}),
    );
    final high = BookSourceQualityScore.fromCandidate(
      candidate(
        1,
        'https://example.com',
        extra: {'ruleContent': '{"content":".text"}', 'lastUpdateTime': 42},
      ),
    );

    expect(high.compareTo(low), greaterThan(0));
    expect(
      high.advantagesOver(low),
      containsAll(['more complete rule groups', 'enabled', 'newer update']),
    );
  });
}

BookSourceDedupeCandidate candidate(
  int index,
  String url, {
  Map<String, dynamic> extra = const {},
  String protocol = 'reading',
  String? installedSourceId,
  bool isReferenced = false,
  bool isHealthy = false,
  int compatibilityRank = 0,
  int runnableCapabilities = 0,
}) {
  return BookSourceDedupeCandidate(
    index: index,
    rawConfig: {
      'bookSourceName': 'Source $index',
      'bookSourceUrl': url,
      ...extra,
    },
    protocol: protocol,
    installedSourceId: installedSourceId,
    isReferenced: isReferenced,
    isHealthy: isHealthy,
    compatibilityRank: compatibilityRank,
    runnableCapabilities: runnableCapabilities,
  );
}
