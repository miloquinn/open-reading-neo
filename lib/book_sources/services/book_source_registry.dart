import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../source_engine/source_config.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';
import 'book_source_registry_storage.dart';
import '../../services/core/app_settings_service.dart';

export 'book_source_registry_storage.dart' show BookSourceRegistryStorage;

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

  final BookSourceRegistryStorage _storage;
  Future<void>? _storagePreparation;

  Stream<void> get changes => _changesController.stream;

  Future<List<RegisteredBookSource>> load() async {
    return loadInBackground();
  }

  /// Moves the old single SharedPreferences blob to file-backed storage before
  /// the rest of the app initializes its preference caches.
  Future<void> prepareStorage() => _storagePreparation ??= _prepareStorage();

  /// Loads the complete registry without parsing a large imported source file
  /// on the UI isolate.
  Future<List<RegisteredBookSource>> loadInBackground() async {
    final raw = await _readRaw();
    if (raw == null || raw.trim().isEmpty) return const [];
    if (raw.length < _backgroundDecodeThreshold) {
      return _decodeStoredSources(raw);
    }
    final maps = await compute(_decodeStoredSourceMaps, raw);
    return maps.map(RegisteredBookSource.fromJson).toList(growable: false);
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
    final maps = raw.length < _backgroundDecodeThreshold
        ? _decodeRunnableSourceMaps(arguments)
        : await compute(_decodeRunnableSourceMaps, arguments);
    return maps.map(RegisteredBookSource.fromJson).toList(growable: false);
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

  Future<void> _save(List<RegisteredBookSource> sources) async {
    final maps = sources
        .map((source) => source.toJson())
        .toList(growable: false);
    final raw = maps.length < 128
        ? jsonEncode(maps)
        : await compute(_encodeStoredSourceMaps, maps);
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
    List<RegisteredBookSource> sources,
  ) async {
    sources.sort((a, b) => a.name.compareTo(b.name));
    await _save(sources);
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
      return 'reading-source:${configuredUrl.trim()}';
    }
  }
  return 'protocol:${source.sourceProtocol.name}:id:${source.id}';
}

List<Map<String, dynamic>> _decodeRunnableSourceMaps(
  Map<String, Object> request,
) {
  final raw = request['raw']! as String;
  final additionalEnabled = request['additionalEnabled']! as bool;
  final sources = _decodeStoredSources(raw).where((source) {
    if (source.capabilities.isEmpty) return false;
    return additionalEnabled ||
        source.sourceProtocol == BookSourceProtocolKind.orsp;
  });
  return sources.map((source) => source.toJson()).toList(growable: false);
}

List<Map<String, dynamic>> _decodeStoredSourceMaps(String raw) {
  return _decodeStoredSources(
    raw,
  ).map((source) => source.toJson()).toList(growable: false);
}

List<RegisteredBookSource> _decodeStoredSources(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final sources = <RegisteredBookSource>[];
    for (final item in decoded) {
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
    return sources;
  } catch (_) {
    return const [];
  }
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
    return compatible.toRegisteredSource(
      id: source.id,
      enabled: source.enabled,
      readingChainVerified: isReadingChainVerifiedSource(source),
      compatibilityReport: effectiveReport,
      addedAt: source.addedAt,
    );
  } on FormatException {
    // Keep a legacy record visible even if its raw configuration can no
    // longer be executed. The management page can still remove or replace it.
    return source;
  }
}

String _encodeStoredSourceMaps(List<Map<String, dynamic>> maps) =>
    jsonEncode(maps);
