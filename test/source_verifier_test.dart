import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_verifier.dart';

ReadingSourceConfig _source(String name, String url, {int lastUpdateTime = 0}) {
  return ReadingSourceConfig.fromJson({
    'bookSourceName': name,
    'bookSourceUrl': url,
    'lastUpdateTime': lastUpdateTime,
    'searchUrl': '/search?q={{key}}',
    'ruleSearch': {'bookList': '.book', 'name': 'a@text', 'bookUrl': 'a@href'},
    'ruleToc': {
      'chapterList': '.chapter',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
    'ruleContent': {'content': '#content'},
  });
}

void main() {
  test(
    'keeps only live-search sources and enables them automatically',
    () async {
      final verifier = SourceVerifier(
        maxConcurrency: 2,
        queries: const ['probe'],
        sourceProbe: (source, _) async => source.name == 'Working',
      );
      addTearDown(verifier.close);

      final result = await verifier.verify([
        _source('Working', 'https://working.example'),
        _source('Empty', 'https://empty.example'),
      ]);

      expect(result.available, hasLength(1));
      expect(result.available.single.name, 'Working');
      expect(result.available.single.enabled, isTrue);
      expect(result.available.single.capabilities, contains('search'));
      expect(
        result
            .available
            .single
            .sourceConfig?['_openReadingReadingChainVerifiedAt'],
        isA<String>(),
      );
      expect(result.rejected, 1);
    },
  );

  test('does not exclude newer HTTP candidates solely by scheme', () async {
    final probed = <String>[];
    final verifier = SourceVerifier(
      maxCandidates: 1,
      maxConcurrency: 1,
      sourceProbe: (source, _) async {
        probed.add(source.name);
        return true;
      },
    );
    addTearDown(verifier.close);

    final result = await verifier.verify([
      _source('New HTTP', 'http://new-http.example', lastUpdateTime: 200),
      _source('Old HTTPS', 'https://old-https.example', lastUpdateTime: 100),
    ]);

    expect(probed, ['New HTTP']);
    expect(result.available.single.name, 'New HTTP');
  });
}
