import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_explore.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/services/core/app_settings_service.dart';

Map<String, dynamic> _source({
  String name = 'Declarative source',
  String url = 'https://books.example',
  int type = 0,
  bool cookies = false,
  String contentRule = '#content@text',
  String? exploreUrl,
  Object? ruleExplore,
}) {
  final source = <String, dynamic>{
    'bookSourceName': name,
    'bookSourceUrl': url,
    'bookSourceType': type,
    'enabledCookieJar': cookies,
    'searchUrl': '/search?q={{key}}',
    'ruleSearch': {'bookList': '.book', 'bookUrl': 'a@href', 'name': 'a@text'},
    'ruleBookInfo': {'name': 'h1@text'},
    'ruleToc': {
      'chapterList': '.chapters a',
      'chapterName': 'text',
      'chapterUrl': 'href',
    },
    'ruleContent': {'content': contentRule},
  };
  if (exploreUrl != null) source['exploreUrl'] = exploreUrl;
  if (ruleExplore != null) source['ruleExplore'] = ruleExplore;
  return source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('parses object, list, wrappers, BOM, and isolates bad items', () {
    final object = parseReadingSources(jsonEncode(_source()));
    expect(object.sources, hasLength(1));

    final list = parseReadingSources(
      '\ufeff${jsonEncode([
        _source(),
        {'bookSourceName': 'Broken'},
        'not-an-object',
      ])}',
    );
    expect(list.sources, hasLength(1));
    expect(list.errors, hasLength(2));

    final wrapper = parseReadingSources(
      jsonEncode({
        'sources': [_source(name: 'Wrapped')],
      }),
    );
    expect(wrapper.sources.single.name, 'Wrapped');
  });

  test('deduplicates by source URL and accepts nested URL bundles', () {
    final parsed = parseReadingSources(
      jsonEncode([_source(name: 'Old'), _source(name: 'New')]),
    );
    expect(parsed.sources.single.name, 'New');

    final nested = parseReadingSources(
      jsonEncode({
        'sourceUrls': [
          'https://example.org/a.json',
          'https://example.org/b.json',
        ],
      }),
    );
    expect(nested.sourceUrls, hasLength(2));
  });

  test(
    'keeps identifier-based sources when their rules expose a web target',
    () {
      final parsed = parseReadingSources(
        jsonEncode([
          {
            ..._source(url: 'Source identity only'),
            'searchUrl': 'https://mirror.example/search?q={{key}}',
          },
        ]),
      );

      expect(parsed.errors, isEmpty);
      expect(parsed.sources.single.url, 'Source identity only');
      expect(
        parsed.sources.single.baseUri,
        Uri.parse('https://mirror.example'),
      );
    },
  );

  test('preflight distinguishes runnable and blocked sources', () {
    const scanner = SourceCompatibilityScanner();
    final supported = scanner.scan(ReadingSourceConfig.fromJson(_source()));
    expect(supported.level, SourceCompatibilityLevel.supported);

    final image = scanner.scan(
      ReadingSourceConfig.fromJson(_source(type: 2, name: 'Images')),
    );
    expect(image.level, SourceCompatibilityLevel.partial);
    expect(image.canRun, isTrue);

    final cookieJar = scanner.scan(
      ReadingSourceConfig.fromJson(_source(cookies: true, name: 'Cookie jar')),
    );
    expect(cookieJar.level, SourceCompatibilityLevel.supported);

    final cookieHeader = scanner.scan(
      ReadingSourceConfig.fromJson({
        ..._source(name: 'Cookie header'),
        'header': '{"Cookie":"sid=1"}',
      }),
    );
    expect(cookieHeader.level, SourceCompatibilityLevel.supported);

    for (final raw in [
      _source(type: 1, name: 'Audio'),
      _source(type: 4, name: 'Video'),
    ]) {
      expect(
        scanner.scan(ReadingSourceConfig.fromJson(raw)).level,
        SourceCompatibilityLevel.unsupported,
      );
    }
    final scripted = scanner.scan(
      ReadingSourceConfig.fromJson(
        _source(contentRule: '@js:result', name: 'Script'),
      ),
    );
    expect(scripted.level, SourceCompatibilityLevel.supported);
    expect(scripted.canRun, isTrue);
  });

  test('metadata comments do not get interpreted as executable rules', () {
    final source = ReadingSourceConfig.fromJson({
      ..._source(),
      'bookSourceComment':
          '// Error: failed to connect to an old mirror during testing',
    });

    expect(const SourceCompatibilityScanner().scan(source).canRun, isTrue);
  });

  test('parses legacy and JSON discovery channels', () {
    final legacy = parseSourceExploreCatalog(
      _source(
        exploreUrl:
            '玄幻::/rank?kind=xuanhuan&page={{page}}&&完本::/finished?page={{page}}',
      ),
    );
    expect(legacy.canBrowse, isTrue);
    expect(
      legacy.entries.map((entry) => entry.title),
      orderedEquals(['玄幻', '完本']),
    );

    final json = parseSourceExploreCatalog(
      _source(
        exploreUrl: jsonEncode([
          {'title': '排行', 'url': '/rank?page={{page}}'},
          {'title': '关键词', 'type': 'text'},
          {'title': '完本', 'type': 'url', 'url': '/finished?page={{page}}'},
        ]),
      ),
    );
    expect(json.canBrowse, isTrue);
    expect(json.hasUnsupportedEntries, isTrue);
    expect(
      json.entries.map((entry) => entry.title),
      orderedEquals(['排行', '完本']),
    );
  });

  test('discovery scripts do not disable an otherwise runnable source', () {
    final source = ReadingSourceConfig.fromJson(
      _source(exploreUrl: '@js:JSON.stringify([])'),
    );

    expect(const SourceCompatibilityScanner().scan(source).canRun, isTrue);
    final registered = source.toRegisteredSource(readingChainVerified: true);
    expect(registered.capabilities, contains('search'));
    expect(registered.capabilities, containsAll(['categories', 'browse']));
    expect(parseSourceExploreCatalog(source.raw).canBrowse, isFalse);
  });

  test('declarative discovery adds categories and browse capabilities', () {
    final registered = ReadingSourceConfig.fromJson(
      _source(exploreUrl: '排行榜::/rank?page={{page}}'),
    ).toRegisteredSource(readingChainVerified: true);

    expect(registered.capabilities, containsAll(['categories', 'browse']));
  });

  test('stored verified sources gain declarative discovery capabilities', () {
    final source = ReadingSourceConfig.fromJson(
      _source(exploreUrl: '排行榜::/rank?page={{page}}'),
    ).toRegisteredSource(readingChainVerified: true);
    final stored = source.toJson()
      ..['capabilities'] = ['search', 'detail', 'catalog', 'content'];

    final restored = RegisteredBookSource.fromJson(stored);

    expect(restored.capabilities, containsAll(['categories', 'browse']));
  });

  test('malformed serialized rules are unsupported instead of crashing', () {
    final raw = _source();
    raw['ruleToc'] = '{not-json';
    final source = ReadingSourceConfig.fromJson(raw);

    expect(source.rule('ruleToc'), isEmpty);
    expect(
      const SourceCompatibilityScanner().scan(source).level,
      SourceCompatibilityLevel.unsupported,
    );
  });

  test('registered compatible source round-trips with config', () {
    final registered = ReadingSourceConfig.fromJson(
      _source(),
    ).toRegisteredSource();
    final restored = RegisteredBookSource.fromJson(registered.toJson());

    expect(restored.sourceProtocol, BookSourceProtocolKind.readingSource);
    expect(restored.sourceConfig?['bookSourceName'], 'Declarative source');
    expect(restored.enabled, isTrue);
  });

  test(
    'registry keeps locally assessed imports without live verification',
    () async {
      final source = ReadingSourceConfig.fromJson(
        _source(),
      ).toRegisteredSource();
      SharedPreferences.setMockInitialValues({
        'open_reading_book_sources_v1': jsonEncode([source.toJson()]),
      });

      expect(await BookSourceRegistry().load(), hasLength(1));
    },
  );

  test(
    'registry migrates the large legacy preference into external storage',
    () async {
      final source = ReadingSourceConfig.fromJson(
        _source(),
      ).toRegisteredSource();
      final stored = source.toJson()
        ..['description'] = ''.padRight(300000, 'x');
      final raw = jsonEncode([stored]);
      expect(raw.length, greaterThan(256 * 1024));
      SharedPreferences.setMockInitialValues({
        'open_reading_book_sources_v1': raw,
      });
      final storage = _MemoryBookSourceRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);

      await registry.prepareStorage();

      final preferences = await SharedPreferences.getInstance();
      expect(storage.raw, raw);
      expect(preferences.containsKey('open_reading_book_sources_v1'), isFalse);
      expect(await registry.load(), hasLength(1));
    },
  );

  test(
    'registry does not report success when external storage update fails',
    () async {
      final source = ReadingSourceConfig.fromJson(
        _source(),
      ).toRegisteredSource(enabled: true);
      final storage = _MemoryBookSourceRegistryStorage(
        raw: jsonEncode([source.toJson()]),
        writeSucceeds: false,
      );
      final registry = BookSourceRegistry(storage: storage);

      await expectLater(
        registry.setEnabled(source.id, false),
        throwsA(isA<StateError>()),
      );

      expect((await registry.load()).single.enabled, isTrue);
    },
  );

  test('registry does not replace an unreadable external registry', () async {
    final source = ReadingSourceConfig.fromJson(
      _source(),
    ).toRegisteredSource(enabled: true);
    final storage = _MemoryBookSourceRegistryStorage(
      readError: Exception('temporarily unreadable'),
    );
    final registry = BookSourceRegistry(storage: storage);
    var publishedChanges = 0;
    final subscription = registry.changes.listen((_) => publishedChanges++);

    await expectLater(registry.upsert(source), throwsA(isA<Exception>()));
    await subscription.cancel();

    final preferences = await SharedPreferences.getInstance();
    expect(storage.writeCalls, 0);
    expect(preferences.containsKey('open_reading_book_sources_v1'), isFalse);
    expect(publishedChanges, 0);
  });

  test('registry refreshes local capabilities without reimporting', () async {
    final source = ReadingSourceConfig.fromJson(_source()).toRegisteredSource();
    final legacy = source.toJson()
      ..['capabilities'] = <String>[]
      ..['enabled'] = false;
    SharedPreferences.setMockInitialValues({
      'open_reading_book_sources_v1': jsonEncode([legacy]),
    });

    final restored = (await BookSourceRegistry().load()).single;
    expect(restored.capabilities, contains('search'));
    expect(restored.enabled, isFalse);
  });

  test(
    'verified bulk import stays enabled and respects runtime gate',
    () async {
      final registry = BookSourceRegistry();
      final original = ReadingSourceConfig.fromJson(
        _source(),
      ).toRegisteredSource(enabled: true, readingChainVerified: true);
      await registry.upsertAll([original]);
      await registry.setEnabled(original.id, true);

      final updated = ReadingSourceConfig.fromJson(
        _source(name: 'Updated'),
      ).toRegisteredSource(enabled: true, readingChainVerified: true);
      final saved = await registry.upsertAll([updated]);
      expect(saved.conflicted, isEmpty);
      expect(saved.sources.single.name, 'Updated');
      expect(saved.sources.single.enabled, isTrue);
      expect(await registry.loadRunnable(), isEmpty);
      expect(await registry.loadRunnableInBackground(), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(additionalSourceProtocolsPreferenceKey, true);
      expect(await registry.loadRunnable(), hasLength(1));
      expect(await registry.loadRunnableInBackground(), hasLength(1));
    },
  );

  test(
    'bulk import skips only the sources whose id conflicts with a '
    'different origin, instead of aborting the whole batch',
    () async {
      final registry = BookSourceRegistry();
      // Two "app" sources that share a non-URL bookSourceUrl (common for
      // aggregator sources whose real host lives inside their script), but
      // whose embedded scripts point at different hosts — a genuine identity
      // conflict, not a re-import of the same source.
      final original = ReadingSourceConfig.fromJson({
        ..._source(name: 'App Source'),
        'bookSourceUrl': 'App Source',
        'jsLib': 'let hosts = ["https://a.example"];',
      }).toRegisteredSource(enabled: true);
      await registry.upsertAll([original]);

      final impostor = ReadingSourceConfig.fromJson({
        ..._source(name: 'App Source (impostor)'),
        'bookSourceUrl': 'App Source',
        'jsLib': 'let hosts = ["https://b.example"];',
      }).toRegisteredSource(enabled: true);
      final freshSource = ReadingSourceConfig.fromJson(
        _source(name: 'Brand New', url: 'https://new.example'),
      ).toRegisteredSource(enabled: true);

      final result = await registry.upsertAll([impostor, freshSource]);

      expect(result.conflicted, hasLength(1));
      expect(result.conflicted.single.name, 'App Source (impostor)');
      expect(
        result.sources.map((source) => source.name),
        containsAll(['App Source', 'Brand New']),
      );
      expect(
        result.sources.map((source) => source.name),
        isNot(contains('App Source (impostor)')),
      );
    },
  );
}

class _MemoryBookSourceRegistryStorage implements BookSourceRegistryStorage {
  _MemoryBookSourceRegistryStorage({
    this.raw,
    this.writeSucceeds = true,
    this.readError,
  });

  String? raw;
  final bool writeSucceeds;
  final Object? readError;
  int writeCalls = 0;

  @override
  Future<String?> read() async {
    if (readError case final error?) throw error;
    return raw;
  }

  @override
  Future<bool> write(String value) async {
    writeCalls++;
    if (!writeSucceeds) return false;
    raw = value;
    return true;
  }
}
