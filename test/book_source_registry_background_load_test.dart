import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/services/core/app_settings_service.dart';

void main() {
  setUp(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    await BookSourceRegistry.resetForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'large background load preserves records, upgrades, and damage isolation',
    () async {
      final alpha = _readingSource(
        name: 'Alpha',
        url: 'https://alpha.example',
        comment: ''.padRight(300000, 'x'),
        enabled: false,
      );
      final zulu = _readingSource(
        name: 'Zulu',
        url: 'https://zulu.example',
        enabled: true,
      );
      final staleAlpha = alpha.toJson()..['capabilities'] = <String>[];
      final raw = jsonEncode([
        zulu.toJson(),
        {'id': 'damaged'},
        staleAlpha,
      ]);
      expect(raw.length, greaterThan(256 * 1024));
      final registry = BookSourceRegistry(storage: _MemoryStorage(raw));

      final loaded = await registry.loadInBackground();

      expect(loaded.map((source) => source.name), ['Alpha', 'Zulu']);
      expect(loaded.first.capabilities, containsAll(['search', 'content']));
      expect(loaded.first.enabled, isFalse);
      expect(loaded.map(_record), [alpha, zulu].map(_record));
    },
  );

  test(
    'large runnable background load respects the protocol preference',
    () async {
      final reading = _readingSource(
        name: 'Alpha reading',
        url: 'https://reading.example',
        comment: ''.padRight(300000, 'x'),
        enabled: true,
      );
      final orsp = RegisteredBookSource(
        id: 'orsp',
        name: 'ORSP',
        description: 'native protocol',
        manifestUrl: Uri.parse('https://orsp.example/.well-known/orsp.json'),
        apiBaseUrl: Uri.parse('https://orsp.example/api'),
        protocolVersion: '1.0',
        languages: const ['zh-CN'],
        capabilities: const {'search'},
        enabled: true,
        addedAt: DateTime.utc(2026),
      );
      final raw = jsonEncode([
        {'id': 'damaged'},
        orsp.toJson(),
        reading.toJson(),
      ]);
      expect(raw.length, greaterThan(256 * 1024));
      final registry = BookSourceRegistry(storage: _MemoryStorage(raw));

      expect(
        (await registry.loadRunnableInBackground()).map(_record),
        [orsp].map(_record),
      );

      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(additionalSourceProtocolsPreferenceKey, true);
      expect(
        (await registry.loadRunnableInBackground()).map(_record),
        [reading, orsp].map(_record),
      );
    },
  );

  test(
    'large v2 group catalog loads without restoring cleared groups',
    () async {
      final alpha = _readingSource(
        name: 'Alpha',
        url: 'https://alpha.example',
        comment: ''.padRight(300000, 'x'),
        enabled: true,
      );
      final zulu = _readingSource(
        name: 'Zulu',
        url: 'https://zulu.example',
        enabled: true,
      );
      final alphaMap = alpha.toJson()
        ..['groups'] = <String>[]
        ..['sourceConfig'] = {
          ...alpha.sourceConfig!,
          'bookSourceGroup': 'Do not restore',
        };
      final zuluMap = zulu.toJson()
        ..remove('groups')
        ..['sourceConfig'] = {
          ...zulu.sourceConfig!,
          'bookSourceGroup': 'Zulu legacy',
        };
      final raw = jsonEncode({
        'version': 2,
        'sources': [zuluMap, alphaMap],
        'groups': ['Empty group'],
      });
      expect(raw.length, greaterThan(256 * 1024));
      final registry = BookSourceRegistry(storage: _MemoryStorage(raw));

      expect(await registry.loadGroups(), ['Empty group', 'Zulu legacy']);
    },
  );
}

RegisteredBookSource _readingSource({
  required String name,
  required String url,
  String comment = '',
  required bool enabled,
}) {
  return ReadingSourceConfig.fromJson({
    'bookSourceName': name,
    'bookSourceUrl': url,
    'bookSourceComment': comment,
    'searchUrl': '/search?q={{key}}',
    'ruleSearch': {'bookList': '.book', 'name': '.name@text'},
    'ruleBookInfo': {'name': 'h1@text'},
    'ruleToc': {'chapterList': '.chapter', 'chapterName': 'a@text'},
    'ruleContent': {'content': '#content@html'},
  }).toRegisteredSource(
    enabled: enabled,
    addedAt: DateTime.utc(2026, name == 'Alpha' ? 1 : 2),
  );
}

Map<String, dynamic> _record(RegisteredBookSource source) => source.toJson();

class _MemoryStorage implements BookSourceRegistryStorage {
  _MemoryStorage(this.raw);

  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
