import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  test('legacy imported groups migrate unless an explicit list exists', () {
    final legacy = _source(sourceGroup: '漫画, 常用；漫画');

    expect(legacy.groups, ['漫画', '常用']);
    final legacyJson = legacy.toJson()..remove('groups');
    expect(RegisteredBookSource.fromJson(legacyJson).groups, ['漫画', '常用']);

    final explicitlyCleared = RegisteredBookSource.fromJson({
      ...legacy.toJson(),
      'groups': <String>[],
    });
    expect(explicitlyCleared.groups, isEmpty);
  });

  test(
    'favorite and explicit clearing persist and survive re-import',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      var changes = 0;
      final subscription = registry.changes.listen((_) => changes++);
      addTearDown(subscription.cancel);

      await registry.upsert(_source(sourceGroup: '导入分组'));
      await registry.setFavorite('source', true);
      await registry.setGroups(const ['source'], const []);
      await registry.upsert(
        _source(name: 'Refreshed source', sourceGroup: '新的导入分组'),
      );
      await registry.upsertAll([
        _source(name: 'Refreshed again', sourceGroup: '另一个导入分组'),
      ]);

      final reloaded = (await registry.load()).single;
      expect(reloaded.name, 'Refreshed again');
      expect(reloaded.isFavorite, isTrue);
      expect(reloaded.groups, isEmpty);
      expect(changes, 5);
    },
  );

  test('mixed group updates preserve unrelated memberships', () async {
    final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    await registry.upsertAll([
      _source(id: 'a', groups: const ['常用', '小说']),
      _source(id: 'b', groups: const ['漫画']),
    ]);

    await registry.updateGroups(
      const ['a', 'b'],
      added: const ['收藏夹'],
      removed: const ['常用'],
    );

    final sources = {
      for (final source in await registry.load()) source.id: source,
    };
    expect(sources['a']!.groups, ['小说', '收藏夹']);
    expect(sources['b']!.groups, ['漫画', '收藏夹']);
  });

  test('synced organization fields replace the local winner', () async {
    final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    await registry.upsert(
      _source(groups: const ['本地']).copyWith(isFavorite: true),
    );

    await registry.applySynced(
      _source(groups: const ['远端']).copyWith(isFavorite: false),
    );

    final source = (await registry.load()).single;
    expect(source.isFavorite, isFalse);
    expect(source.groups, ['远端']);
  });

  test(
    'empty groups persist, reorder, rename, and delete without deleting sources',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      await registry.upsert(_source(groups: const ['有成员']));

      await registry.createGroup('空分组');
      expect(await registry.loadGroups(), ['有成员', '空分组']);

      await registry.reorderGroups(const ['空分组', '有成员']);
      expect(await registry.loadGroups(), ['空分组', '有成员']);

      await registry.renameGroup('空分组', '稍后整理');
      expect(await registry.loadGroups(), ['稍后整理', '有成员']);

      await registry.deleteGroup('有成员');
      expect(await registry.loadGroups(), ['稍后整理']);
      final source = (await registry.load()).single;
      expect(source.id, 'source');
      expect(source.groups, isEmpty);

      final restored = BookSourceRegistry(
        storage: _MemoryRegistryStorage(storage.raw),
      );
      expect(await restored.loadGroups(), ['稍后整理']);
      expect((await restored.load()).single.id, 'source');
    },
  );
}

RegisteredBookSource _source({
  String id = 'source',
  String name = 'Source',
  String? sourceGroup,
  List<String>? groups,
}) => RegisteredBookSource(
  id: id,
  name: name,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/api/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  groups: groups,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {
    'bookSourceName': name,
    'bookSourceUrl': 'https://$id.example',
    'searchUrl': '/search?q={{key}}',
    'ruleSearch': {'bookList': '.book', 'name': '.name@text'},
    // ignore: use_null_aware_elements
    if (sourceGroup != null) 'bookSourceGroup': sourceGroup,
  },
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
