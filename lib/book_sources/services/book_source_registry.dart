import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../source_engine/source_config.dart';
import '../dedupe/book_source_identity.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';
import 'book_source_registry_storage.dart';
import '../../services/core/app_settings_service.dart';
import 'book_source_health_configuration.dart';

export 'book_source_registry_storage.dart' show BookSourceRegistryStorage;
export 'book_source_health_configuration.dart';

/// Result of [BookSourceRegistry.upsertAll]: the full registry after the
/// write, plus any imported sources that were held back because they would
/// have silently taken over an existing source's id from a different origin.
@immutable
class BookSourceUpsertAllResult {
  const BookSourceUpsertAllResult({
    required this.sources,
    required this.conflicted,
  });

  final List<RegisteredBookSource> sources;
  final List<RegisteredBookSource> conflicted;
}

class BookSourceRegistry {
  BookSourceRegistry({BookSourceRegistryStorage? storage})
    : _storage = storage ?? const DefaultBookSourceRegistryStorage();

  static const String _storageKey = 'open_reading_book_sources_v1';
  static const int _backgroundDecodeThreshold = 256 * 1024;
  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static Future<void> _mutationTail = Future<void>.value();
  static Future<void>? _storagePreparation;

  final BookSourceRegistryStorage _storage;

  Stream<void> get changes => _changesController.stream;

  Future<List<RegisteredBookSource>> load() async {
    return loadInBackground();
  }

  /// Moves the old single SharedPreferences blob to file-backed storage before
  /// the rest of the app initializes its preference caches.
  Future<void> prepareStorage() => _storagePreparation ??= _prepareStorage();

  /// Drains the process-wide mutation tail and re-arms storage migration so
  /// the next test does not inherit a rejected future or a stale prepare.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    try {
      await _mutationTail;
    } catch (_) {
      // A failed mutate must not poison the next test's tail.
    }
    _mutationTail = Future<void>.value();
    _storagePreparation = null;
  }

  /// Loads the complete registry without parsing a large imported source file
  /// on the UI isolate.
  Future<List<RegisteredBookSource>> loadInBackground() async {
    final raw = await _readRaw();
    if (raw == null || raw.trim().isEmpty) return const [];
    if (raw.length < _backgroundDecodeThreshold) {
      return _decodeStoredSources(raw);
    }
    return compute(_decodeStoredSources, raw);
  }

  Future<List<RegisteredBookSource>> _load() async {
    return loadInBackground();
  }

  /// Returns sources that may participate in runtime requests right now.
  /// Compatible sources stay stored while the global advanced feature is off.
  Future<List<RegisteredBookSource>> loadRunnable() async {
    final loaded = await load();
    final preferences = await SharedPreferences.getInstance();
    final additionalEnabled =
        preferences.getBool(additionalSourceProtocolsPreferenceKey) ?? false;
    final runnable = loaded.where((source) => source.capabilities.isNotEmpty);
    if (additionalEnabled) return runnable.toList(growable: false);
    return runnable
        .where((source) => source.sourceProtocol == BookSourceProtocolKind.orsp)
        .toList(growable: false);
  }

  /// Loads the runnable set without decoding and compatibility-scanning a
  /// large imported registry on the UI isolate.
  Future<List<RegisteredBookSource>> loadRunnableInBackground() async {
    final raw = await _readRaw();
    if (raw == null || raw.trim().isEmpty) return const [];
    final preferences = await SharedPreferences.getInstance();
    final additionalEnabled =
        preferences.getBool(additionalSourceProtocolsPreferenceKey) ?? false;
    final arguments = <String, Object>{
      'raw': raw,
      'additionalEnabled': additionalEnabled,
    };
    // Spawning an isolate costs more than a direct parse for small source
    // lists and does not advance inside Flutter widget-test fake async. Large
    // imported registries still stay completely off the UI isolate.
    return raw.length < _backgroundDecodeThreshold
        ? _decodeRunnableSources(arguments)
        : compute(_decodeRunnableSources, arguments);
  }

  Future<List<RegisteredBookSource>> upsert(RegisteredBookSource source) async {
    return _mutate(() async {
      final sources = (await _load()).toList();
      final index = sources.indexWhere((item) => item.id == source.id);
      if (index >= 0) {
        final previous = sources[index];
        // 防止书源 id 劫持：清单 id 由服务端自报，若同 id 的源来自
        // 不同域名，则拒绝静默覆盖已注册源的 API 地址。用户如确要
        // 更换域名，需先删除旧源再添加。
        final sameOrigin =
            previous.manifestUrl.host == source.manifestUrl.host &&
            previous.apiBaseUrl.host == source.apiBaseUrl.host;
        if (!sameOrigin) {
          throw BookSourceProtocolException(
            'A source with id "${source.id}" is already registered from '
            '${previous.manifestUrl.host}. Remove it first before adding a '
            'source with the same id from a different host.',
          );
        }
        sources[index] = RegisteredBookSource(
          id: source.id,
          name: source.name,
          description: source.description,
          manifestUrl: source.manifestUrl,
          apiBaseUrl: source.apiBaseUrl,
          iconUrl: source.iconUrl,
          websiteUrl: source.websiteUrl,
          operatorName: source.operatorName,
          contactUrl: source.contactUrl,
          contentLicense: source.contentLicense,
          rightsStatement: source.rightsStatement,
          protocolVersion: source.protocolVersion,
          languages: source.languages,
          capabilities: source.capabilities,
          maxCatalogPageSize: source.maxCatalogPageSize,
          enabled: previous.enabled,
          isFavorite: previous.isFavorite,
          groups: previous.groups,
          addedAt: previous.addedAt,
          sourceProtocol: source.sourceProtocol,
          sourceConfig: source.sourceConfig,
        );
      } else {
        sources.add(source);
      }
      return _saveAndPublish(sources);
    });
  }

  /// Adds or refreshes a bounded import batch in one serialized write.
  /// Existing entries keep their local enabled state and original add time.
  ///
  /// A batch commonly re-imports sources the user already has (the same
  /// aggregate file, fetched again; overlapping entries across several
  /// collections). Those are normal, expected duplicates and must not stop
  /// the rest of the batch from importing. Only a genuine identity conflict —
  /// the same id/URL now claiming a different origin, which could otherwise
  /// silently hijack an existing source's API endpoint — is held back; it is
  /// reported via [BookSourceUpsertAllResult.conflicted] instead of aborting
  /// the whole import.
  Future<BookSourceUpsertAllResult> upsertAll(
    Iterable<RegisteredBookSource> imported,
  ) async {
    final conflicted = <RegisteredBookSource>[];
    final sources = await _mutate(() async {
      final sources = (await _load()).toList();
      final indexes = <String, int>{
        for (var index = 0; index < sources.length; index++)
          _sourceIdentity(sources[index]): index,
      };
      for (final source in imported) {
        final identity = _sourceIdentity(source);
        final index = indexes[identity];
        if (index == null) {
          indexes[identity] = sources.length;
          sources.add(source);
          continue;
        }
        final previous = sources[index];
        final sameOrigin =
            previous.manifestUrl.host == source.manifestUrl.host &&
            previous.apiBaseUrl.host == source.apiBaseUrl.host &&
            previous.sourceProtocol == source.sourceProtocol;
        if (!sameOrigin) {
          conflicted.add(source);
          continue;
        }
        sources[index] = RegisteredBookSource(
          // Preserve the original ID when migrating imported-source naming;
          // shelf entries and downloaded books may already reference it.
          id: previous.id,
          name: source.name,
          description: source.description,
          manifestUrl: source.manifestUrl,
          apiBaseUrl: source.apiBaseUrl,
          iconUrl: source.iconUrl,
          websiteUrl: source.websiteUrl,
          operatorName: source.operatorName,
          contactUrl: source.contactUrl,
          contentLicense: source.contentLicense,
          rightsStatement: source.rightsStatement,
          protocolVersion: source.protocolVersion,
          languages: source.languages,
          capabilities: source.capabilities,
          maxCatalogPageSize: source.maxCatalogPageSize,
          enabled: previous.enabled && source.capabilities.isNotEmpty,
          isFavorite: previous.isFavorite,
          groups: previous.groups,
          addedAt: previous.addedAt,
          sourceProtocol: source.sourceProtocol,
          sourceConfig: source.sourceConfig,
        );
      }
      return _saveAndPublish(sources);
    });
    return BookSourceUpsertAllResult(
      sources: sources,
      conflicted: List.unmodifiable(conflicted),
    );
  }

  Future<List<RegisteredBookSource>> setEnabled(String id, bool enabled) async {
    return _mutate(() async {
      final sources = (await _load())
          .map((source) {
            if (source.id != id) return source;
            if (enabled && source.capabilities.isEmpty) {
              throw const BookSourceProtocolException(
                'This source cannot be enabled because its rules are unsupported.',
              );
            }
            return source.copyWith(enabled: enabled);
          })
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  Future<List<RegisteredBookSource>> setFavorite(String id, bool value) async {
    return _mutate(() async {
      final sources = (await _load())
          .map(
            (source) =>
                source.id == id ? source.copyWith(isFavorite: value) : source,
          )
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  /// Replaces the complete group membership of every selected source.
  Future<List<RegisteredBookSource>> setGroups(
    Iterable<String> ids,
    Iterable<String> groups,
  ) async {
    final selected = ids.toSet();
    final normalized = _normalizeGroupNames(groups);
    return _mutate(() async {
      final sources = (await _load())
          .map(
            (source) => selected.contains(source.id)
                ? source.copyWith(groups: normalized)
                : source,
          )
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  /// Adds and removes memberships without disturbing different existing
  /// memberships across a mixed multi-selection.
  Future<List<RegisteredBookSource>> updateGroups(
    Iterable<String> ids, {
    required Iterable<String> added,
    required Iterable<String> removed,
  }) async {
    final selected = ids.toSet();
    final addedGroups = _normalizeGroupNames(added);
    final removedGroups = _normalizeGroupNames(removed).toSet();
    return _mutate(() async {
      final sources = (await _load())
          .map((source) {
            if (!selected.contains(source.id)) return source;
            final next = source.groups
                .where((group) => !removedGroups.contains(group))
                .toList();
            for (final group in addedGroups) {
              if (!next.contains(group)) next.add(group);
            }
            return source.copyWith(groups: next);
          })
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  /// Loads the explicit group order followed by any memberships found on
  /// sources imported from an older or externally synced record.
  Future<List<String>> loadGroups() async {
    final raw = await _readRaw();
    if (raw == null || raw.trim().isEmpty) return const [];
    final groups = raw.length < _backgroundDecodeThreshold
        ? _decodeStoredGroupNames(raw)
        : await compute(_decodeStoredGroupNames, raw);
    return List.unmodifiable(groups);
  }

  Future<List<String>> createGroup(String name) async {
    final group = _requiredGroupName(name);
    return _mutate(() async {
      final sources = await _load();
      final groups = await loadGroups();
      final next = groups.contains(group) ? groups : [...groups, group];
      await _saveAndPublish(sources, groups: next);
      return List.unmodifiable(next);
    });
  }

  Future<List<String>> renameGroup(String oldName, String newName) async {
    final oldGroup = _requiredGroupName(oldName);
    final newGroup = _requiredGroupName(newName);
    return _mutate(() async {
      final sources = (await _load())
          .map((source) {
            if (!source.groups.contains(oldGroup)) return source;
            return source.copyWith(
              groups: _normalizeGroupNames(
                source.groups.map(
                  (group) => group == oldGroup ? newGroup : group,
                ),
              ),
            );
          })
          .toList(growable: false);
      final groups = (await loadGroups()).map(
        (group) => group == oldGroup ? newGroup : group,
      );
      final next = _normalizeGroupNames(groups);
      await _saveAndPublish(sources, groups: next);
      return List.unmodifiable(next);
    });
  }

  Future<List<String>> deleteGroup(String name) async {
    final group = _requiredGroupName(name);
    return _mutate(() async {
      final sources = (await _load())
          .map(
            (source) => source.groups.contains(group)
                ? source.copyWith(
                    groups: source.groups
                        .where((item) => item != group)
                        .toList(),
                  )
                : source,
          )
          .toList(growable: false);
      final next = (await loadGroups())
          .where((item) => item != group)
          .toList(growable: false);
      await _saveAndPublish(sources, groups: next);
      return List.unmodifiable(next);
    });
  }

  Future<List<String>> reorderGroups(List<String> groups) async {
    final requested = _normalizeGroupNames(groups);
    return _mutate(() async {
      final sources = await _load();
      final current = await loadGroups();
      final next = <String>[
        ...requested.where(current.contains),
        ...current.where((group) => !requested.contains(group)),
      ];
      await _saveAndPublish(sources, groups: next);
      return List.unmodifiable(next);
    });
  }

  /// Re-fetches a saved source's manifest while retaining local user choices.
  /// A manifest is not allowed to change the registered source identity.
  Future<List<RegisteredBookSource>> refresh(
    RegisteredBookSource source,
    BookSourceClient client,
  ) async {
    final manifestInput = source.manifestUrl.toString();
    await client.invalidateDiscoveryResponseCache(manifestInput);
    final discovered = await client.discover(manifestInput);
    final refreshed = RegisteredBookSource.fromManifest(
      manifest: discovered.manifest,
      manifestUrl: discovered.manifestUrl,
    );
    if (refreshed.id != source.id) {
      throw const BookSourceProtocolException(
        'The refreshed manifest changed the source ID. Remove the old source before adding it again.',
      );
    }
    return upsert(refreshed);
  }

  Future<List<RegisteredBookSource>> remove(String id) async {
    return _mutate(() async {
      final sources = (await _load())
          .where((source) => source.id != id)
          .toList();
      return _saveAndPublish(sources);
    });
  }

  Future<List<RegisteredBookSource>> removeAll(Iterable<String> ids) async {
    final removed = ids.toSet();
    return _mutate(() async {
      final sources = (await _load())
          .where((source) => !removed.contains(source.id))
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  Future<List<RegisteredBookSource>> setEnabledAll(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final selected = ids.toSet();
    return _mutate(() async {
      final sources = (await _load())
          .map((source) {
            if (!selected.contains(source.id)) return source;
            final canEnable = source.capabilities.isNotEmpty;
            return source.copyWith(enabled: enabled && canEnable);
          })
          .toList(growable: false);
      return _saveAndPublish(sources);
    });
  }

  /// Merges only completed health-check metadata into sources that still
  /// exist. The current registry record remains authoritative for user-owned
  /// fields such as enabled state, groups, order, and any edits made while a
  /// long-running check was in flight.
  Future<BookSourceHealthMergeResult> mergeHealthCheckResults(
    Iterable<RegisteredBookSource> checkedSources, {
    Set<String>? persistSourceIds,
  }) async {
    final checkedById = <String, RegisteredBookSource>{};
    for (final source in checkedSources) {
      final health = source.sourceConfig?['_openReadingHealthCheck'];
      if (health != null) checkedById[source.id] = source;
    }
    if (checkedById.isEmpty) {
      return BookSourceHealthMergeResult(
        sources: await load(),
        mergedSourceIds: const {},
      );
    }
    return _mutate(() async {
      final mergedSourceIds = <String>{};
      var changed = false;
      final sources = (await _load())
          .map((source) {
            final checked = checkedById[source.id];
            if (checked == null ||
                !sameBookSourceHealthCheckConfiguration(source, checked)) {
              return source;
            }
            mergedSourceIds.add(source.id);
            if (persistSourceIds != null &&
                !persistSourceIds.contains(source.id)) {
              return source;
            }
            changed = true;
            return source.copyWith(
              sourceConfig: {
                ...?source.sourceConfig,
                '_openReadingHealthCheck':
                    checked.sourceConfig!['_openReadingHealthCheck'],
              },
            );
          })
          .toList(growable: false);
      final List<RegisteredBookSource> saved;
      try {
        saved = changed
            ? await _saveAndPublish(sources)
            : List<RegisteredBookSource>.unmodifiable(sources);
      } on Object catch (error) {
        final persistedCandidates = persistSourceIds == null
            ? mergedSourceIds
            : mergedSourceIds.intersection(persistSourceIds);
        throw BookSourceHealthMergePersistenceException(
          cause: error,
          unpersistedSourceIds: Set.unmodifiable(persistedCandidates),
        );
      }
      return BookSourceHealthMergeResult(
        sources: saved,
        mergedSourceIds: Set.unmodifiable(mergedSourceIds),
      );
    });
  }

  /// Applies an exact record-level winner received from the user's sync space.
  ///
  /// Unlike manifest refresh, sync must preserve the remote device's enabled
  /// state and added time because those fields are part of the synced record.
  Future<List<RegisteredBookSource>> applySynced(
    RegisteredBookSource source,
  ) async {
    return _mutate(() async {
      final sources = (await _load()).toList();
      final index = sources.indexWhere((item) => item.id == source.id);
      if (index < 0) {
        sources.add(source);
      } else {
        sources[index] = source;
      }
      return _saveAndPublish(sources);
    });
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    Future<void> run(_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }

    _mutationTail = _mutationTail.then<void>(run, onError: run);
    return completer.future;
  }

  Future<void> _save(
    List<RegisteredBookSource> sources,
    List<String> groups,
  ) async {
    final maps = sources
        .map((source) => source.toJson())
        .toList(growable: false);
    final stored = <String, Object>{
      'version': 2,
      'sources': maps,
      'groups': groups,
    };
    final raw = maps.length < 128
        ? jsonEncode(stored)
        : await compute(_encodeStoredRegistry, stored);
    final hasExternalRegistry = await _storage.read() != null;
    if (await _storage.write(raw)) {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.containsKey(_storageKey)) {
        await preferences.remove(_storageKey);
      }
      return;
    }
    if (hasExternalRegistry) {
      throw StateError('Could not persist the book source registry.');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storageKey, raw);
  }

  Future<List<RegisteredBookSource>> _saveAndPublish(
    List<RegisteredBookSource> sources, {
    List<String>? groups,
  }) async {
    sources.sort((a, b) => a.name.compareTo(b.name));
    final existingGroups = groups ?? await loadGroups();
    final orderedGroups = _mergeGroupOrder(existingGroups, sources);
    await _save(sources, orderedGroups);
    _changesController.add(null);
    return List.unmodifiable(sources);
  }

  Future<void> _prepareStorage() async {
    if (await _storage.read() != null) return;
    final preferences = await SharedPreferences.getInstance();
    final legacy = preferences.getString(_storageKey);
    if (legacy == null) return;
    if (await _storage.write(legacy)) {
      await preferences.remove(_storageKey);
    }
  }

  Future<String?> _readRaw() async {
    await prepareStorage();
    final stored = await _storage.read();
    if (stored != null) return stored;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_storageKey);
  }
}

String _sourceIdentity(RegisteredBookSource source) {
  if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
    final configuredUrl = source.sourceConfig?['bookSourceUrl'];
    if (configuredUrl is String && configuredUrl.trim().isNotEmpty) {
      return 'reading-source:${BookSourceIdentity.parse(configuredUrl).canonicalKey}';
    }
  }
  return 'protocol:${source.sourceProtocol.name}:id:${source.id}';
}

List<RegisteredBookSource> _decodeRunnableSources(Map<String, Object> request) {
  final raw = request['raw']! as String;
  final additionalEnabled = request['additionalEnabled']! as bool;
  final sources = _decodeStoredSources(raw).where((source) {
    if (source.capabilities.isEmpty) return false;
    return additionalEnabled ||
        source.sourceProtocol == BookSourceProtocolKind.orsp;
  });
  return sources.toList(growable: false);
}

List<RegisteredBookSource> _decodeStoredSources(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return _decodeStoredRegistryValue(decoded).sources;
  } catch (_) {
    return const [];
  }
}

_StoredBookSourceRegistry _decodeStoredRegistryValue(Object? decoded) {
  final sourceItems = decoded is List
      ? decoded
      : decoded is Map && decoded['sources'] is List
      ? decoded['sources']! as List
      : const [];
  final explicitGroups = decoded is Map && decoded['groups'] is List
      ? _normalizeGroupNames((decoded['groups']! as List).whereType<String>())
      : const <String>[];
  final sources = <RegisteredBookSource>[];
  for (final item in sourceItems) {
    if (item is! Map) continue;
    try {
      final stored = RegisteredBookSource.fromJson(
        item.map((key, value) => MapEntry('$key', value)),
      );
      sources.add(_refreshStoredCompatibility(stored));
    } catch (_) {
      // One damaged record must not hide the remaining sources.
    }
  }
  sources.sort((a, b) => a.name.compareTo(b.name));
  return _StoredBookSourceRegistry(sources: sources, groups: explicitGroups);
}

List<String> _decodeStoredGroupNames(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final sourceItems = decoded is List
        ? decoded
        : decoded is Map && decoded['sources'] is List
        ? decoded['sources']! as List
        : const [];
    final groups = decoded is Map && decoded['groups'] is List
        ? _normalizeGroupNames((decoded['groups']! as List).whereType<String>())
        : <String>[];
    final groupRecords = <({String name, List<String> groups})>[];
    for (final item in sourceItems) {
      if (item is! Map) continue;
      final name = item['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final sourceGroups = item.containsKey('groups')
          ? _storedGroupList(item['groups'])
          : _legacyStoredGroupList(item['sourceConfig']);
      groupRecords.add((name: name.trim(), groups: sourceGroups));
    }
    groupRecords.sort((a, b) => a.name.compareTo(b.name));
    final seen = groups.toSet();
    for (final record in groupRecords) {
      for (final group in record.groups) {
        if (seen.add(group)) groups.add(group);
      }
    }
    return groups;
  } catch (_) {
    return const [];
  }
}

List<String> _storedGroupList(Object? value) =>
    value is List ? _normalizeGroupNames(value.whereType<String>()) : const [];

List<String> _legacyStoredGroupList(Object? sourceConfig) {
  if (sourceConfig is! Map) return const [];
  final value = sourceConfig['bookSourceGroup'];
  if (value is! String || value.trim().isEmpty) return const [];
  return _normalizeGroupNames(value.split(RegExp(r'[,;，；\n]')));
}

RegisteredBookSource _refreshStoredCompatibility(RegisteredBookSource source) {
  if (source.sourceProtocol != BookSourceProtocolKind.readingSource ||
      source.sourceConfig == null) {
    return source;
  }
  try {
    final compatible = ReadingSourceConfig.fromJson(source.sourceConfig!);
    // Compatibility is policy, not source data. Always rescan so upgrades
    // (for example image sources becoming supported) take effect immediately.
    final effectiveReport = const SourceCompatibilityScanner().scan(compatible);
    return compatible
        .toRegisteredSource(
          id: source.id,
          enabled: source.enabled,
          readingChainVerified: isReadingChainVerifiedSource(source),
          compatibilityReport: effectiveReport,
          addedAt: source.addedAt,
        )
        .copyWith(isFavorite: source.isFavorite, groups: source.groups);
  } on FormatException {
    // Keep a legacy record visible even if its raw configuration can no
    // longer be executed. The management page can still remove or replace it.
    return source;
  }
}

List<String> _normalizeGroupNames(Iterable<String> groups) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final group in groups) {
    final value = group.trim();
    if (value.isNotEmpty && seen.add(value)) normalized.add(value);
  }
  return normalized;
}

String _requiredGroupName(String name) {
  final normalized = name.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(name, 'name', 'Group name must not be empty.');
  }
  return normalized;
}

List<String> _mergeGroupOrder(
  Iterable<String> explicitGroups,
  Iterable<RegisteredBookSource> sources,
) {
  final groups = _normalizeGroupNames(explicitGroups);
  final seen = groups.toSet();
  for (final source in sources) {
    for (final group in source.groups) {
      if (seen.add(group)) groups.add(group);
    }
  }
  return groups;
}

String _encodeStoredRegistry(Map<String, Object> value) => jsonEncode(value);

class _StoredBookSourceRegistry {
  const _StoredBookSourceRegistry({
    required this.sources,
    required this.groups,
  });

  final List<RegisteredBookSource> sources;
  final List<String> groups;
}
