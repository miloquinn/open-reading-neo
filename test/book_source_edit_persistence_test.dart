import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  test('edited reading source persists and reloads derived fields', () async {
    final storage = _MemoryRegistryStorage();
    final registry = BookSourceRegistry(storage: storage);
    await registry.upsert(_source());

    await registry.updateReadingSource('stable-id', {
      ..._config(),
      'bookSourceName': 'Edited source',
      'bookSourceComment': 'Edited description',
      'bookSourceGroup': '小说, 常用',
      'enabled': false,
      'searchUrl': '/new-search?q={{key}}',
      'ruleExplore': {
        'bookList': '.card',
        'extension': {
          'labels': ['one', 'two'],
        },
      },
    });

    final reloaded = (await BookSourceRegistry(
      storage: _MemoryRegistryStorage(storage.raw),
    ).load()).single;
    expect(reloaded.name, 'Edited source');
    expect(reloaded.description, 'Edited description');
    expect(reloaded.enabled, isFalse);
    expect(reloaded.groups, ['小说', '常用']);
    expect(
      reloaded.capabilities,
      containsAll(const {'search', 'catalog', 'content'}),
    );
    expect(reloaded.sourceConfig?['searchUrl'], '/new-search?q={{key}}');
    expect(reloaded.sourceConfig?['ruleExplore'], {
      'bookList': '.card',
      'extension': {
        'labels': ['one', 'two'],
      },
    });
  });

  test('URL edits keep source identity and local bookkeeping stable', () async {
    final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    final addedAt = DateTime.utc(2025, 2, 3, 4, 5);
    await registry.upsert(_source(addedAt: addedAt));

    final edited = (await registry.updateReadingSource('stable-id', {
      ..._config(),
      'bookSourceUrl': 'https://moved.example/new-root/',
      'bookSourceName': 'Moved source',
    })).single;

    expect(edited.id, 'stable-id');
    expect(edited.manifestUrl, Uri.parse('https://moved.example/new-root/'));
    expect(edited.apiBaseUrl, Uri.parse('https://moved.example/new-root/'));
    expect(edited.isFavorite, isTrue);
    expect(edited.addedAt, addedAt);
  });

  test(
    'URL edit rejects another source canonical identity without writes',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      final other = ReadingSourceConfig.fromJson({
        ..._config(),
        'bookSourceName': 'Other source',
        'bookSourceUrl': 'https://other.example/path/?b=2&a=1',
      }).toRegisteredSource(id: 'other-id');
      await registry.upsertAll([_source(), other]);
      final before = storage.raw;

      await expectLater(
        registry.updateReadingSource('stable-id', {
          ..._config(),
          'bookSourceUrl':
              'https://OTHER.example/path?a=1&b=2&utm_source=ignored',
        }),
        throwsA(
          isA<ReadingSourceEditConflictException>().having(
            (error) => error.conflictingSourceId,
            'conflictingSourceId',
            'other-id',
          ),
        ),
      );

      expect(storage.raw, before);
      final sources = await registry.load();
      expect(sources, hasLength(2));
      expect(
        sources.singleWhere((source) => source.id == 'stable-id').manifestUrl,
        Uri.parse('https://old.example'),
      );
      expect(
        sources.singleWhere((source) => source.id == 'other-id').manifestUrl,
        Uri.parse('https://other.example/path/?b=2&a=1'),
      );
    },
  );

  test(
    'changed configuration invalidates health and reading-chain evidence',
    () async {
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      await registry.upsert(_source());

      final editedConfig = {...?_source().sourceConfig}
        ..['searchUrl'] = '/changed?q={{key}}';
      final edited = (await registry.updateReadingSource(
        'stable-id',
        editedConfig,
      )).single;

      expect(edited.sourceConfig, isNot(contains('_openReadingHealthCheck')));
      expect(
        edited.sourceConfig,
        isNot(contains('_openReadingReadingChainVerifiedAt')),
      );
      expect(edited.sourceConfig?['_openReadingCompatibilityLevel'], isNotNull);
    },
  );

  test(
    'an unchanged full configuration retains verification evidence',
    () async {
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      final source = _source();
      await registry.upsert(source);

      final edited = (await registry.updateReadingSource(
        source.id,
        source.sourceConfig!,
      )).single;

      expect(edited.sourceConfig?['_openReadingHealthCheck'], {
        'healthy': true,
      });
      expect(
        edited.sourceConfig?['_openReadingReadingChainVerifiedAt'],
        '2026-01-02T03:04:05.000Z',
      );
    },
  );

  test('invalid configuration is rejected without changing storage', () async {
    final storage = _MemoryRegistryStorage();
    final registry = BookSourceRegistry(storage: storage);
    await registry.upsert(_source());
    final before = storage.raw;

    await expectLater(
      registry.updateReadingSource('stable-id', {
        ..._config(),
        'bookSourceUrl': 'relative/path',
      }),
      throwsA(isA<FormatException>()),
    );

    expect(storage.raw, before);
    expect((await registry.load()).single.name, 'Original source');
  });

  test(
    'missing and protocol sources cannot be edited as reading sources',
    () async {
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      await registry.upsert(_protocolSource());

      await expectLater(
        registry.updateReadingSource('missing', _config()),
        throwsA(isA<BookSourceProtocolException>()),
      );
      await expectLater(
        registry.updateReadingSource('protocol-id', _config()),
        throwsA(isA<BookSourceProtocolException>()),
      );
    },
  );
}

Map<String, dynamic> _config() => {
  'bookSourceName': 'Original source',
  'bookSourceUrl': 'https://old.example',
  'bookSourceComment': 'Original description',
  'enabled': true,
  'searchUrl': '/search?q={{key}}',
  'ruleSearch': {'bookList': '.book', 'name': '.name@text'},
  'ruleToc': {'chapterList': '.chapter', 'chapterName': '@text'},
  'ruleContent': {'content': '#content@html'},
};

RegisteredBookSource _source({DateTime? addedAt}) {
  final registered = ReadingSourceConfig.fromJson(
    _config(),
  ).toRegisteredSource(id: 'stable-id', addedAt: addedAt ?? DateTime.utc(2026));
  return RegisteredBookSource(
    id: registered.id,
    name: registered.name,
    description: registered.description,
    manifestUrl: registered.manifestUrl,
    apiBaseUrl: registered.apiBaseUrl,
    iconUrl: Uri.parse('https://old.example/icon.png'),
    websiteUrl: registered.websiteUrl,
    operatorName: 'Local operator metadata',
    protocolVersion: registered.protocolVersion,
    languages: const ['zh-CN'],
    capabilities: registered.capabilities,
    enabled: registered.enabled,
    isFavorite: true,
    groups: const ['旧分组'],
    addedAt: registered.addedAt,
    sourceProtocol: registered.sourceProtocol,
    sourceConfig: {
      ...?registered.sourceConfig,
      '_openReadingHealthCheck': {'healthy': true},
      '_openReadingReadingChainVerifiedAt': '2026-01-02T03:04:05.000Z',
    },
  );
}

RegisteredBookSource _protocolSource() => RegisteredBookSource(
  id: 'protocol-id',
  name: 'Protocol source',
  description: '',
  manifestUrl: Uri.parse('https://protocol.example/source.json'),
  apiBaseUrl: Uri.parse('https://protocol.example/api/'),
  protocolVersion: '1.0',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  _MemoryRegistryStorage([this.raw]);

  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
