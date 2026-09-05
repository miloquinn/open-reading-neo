import 'sync_models.dart';

/// Stable protocol datasets and the capabilities exposed by this release.
///
/// Unsupported datasets remain reserved in the protocol. Remote records can
/// stay in `sync_records` without being scanned from or materialized into the
/// app's business tables. A future release can enable the capability and
/// materialize those retained records without changing remote identities.
enum SyncDataset {
  bookSources('book_sources'),
  books('books'),
  progress('progress'),
  bookmarks('bookmarks'),
  notes('notes'),
  readingSessions('reading_sessions'),
  readerSettings('reader_settings'),
  readerThemes('reader_themes'),
  replaceRules('replace_rules');

  const SyncDataset(this.remoteName);

  final String remoteName;

  static SyncDataset? fromRemoteName(String value) {
    for (final dataset in values) {
      if (dataset.remoteName == value) return dataset;
    }
    return null;
  }
}

class SyncDatasetCatalog {
  const SyncDatasetCatalog._();

  static bool isSupported(SyncDataset dataset) => switch (dataset) {
    SyncDataset.bookSources ||
    SyncDataset.books ||
    SyncDataset.progress ||
    SyncDataset.bookmarks ||
    SyncDataset.notes ||
    SyncDataset.readingSessions ||
    SyncDataset.readerSettings ||
    SyncDataset.readerThemes ||
    SyncDataset.replaceRules => true,
  };

  static bool isEnabled(SyncDataset dataset, WebDavSyncScope scope) {
    if (!isSupported(dataset)) return false;
    return switch (dataset) {
      SyncDataset.bookSources => scope.bookSources,
      SyncDataset.books => scope.books,
      SyncDataset.progress => scope.progress,
      SyncDataset.bookmarks => scope.bookmarks,
      SyncDataset.notes => scope.notes,
      SyncDataset.readingSessions => scope.readingSessions,
      SyncDataset.readerSettings ||
      SyncDataset.readerThemes => scope.readerSettings,
      SyncDataset.replaceRules => scope.replaceRules,
    };
  }

  static WebDavSyncScope normalizeScope(WebDavSyncScope scope) => scope;

  static bool isRecordPublishable({
    required String dataset,
    required String recordId,
    String entityKey = '',
    Map<String, dynamic>? payload,
    required WebDavSyncScope scope,
  }) {
    final parsed = SyncDataset.fromRemoteName(dataset);
    if (parsed == null || !isEnabled(parsed, scope)) return false;
    if (isPermanentlyBlockedRecord(
      dataset: dataset,
      recordId: recordId,
      entityKey: entityKey,
      payload: payload,
    )) {
      return false;
    }
    return true;
  }

  static bool isPermanentlyBlockedRecord({
    required String dataset,
    required String recordId,
    required String entityKey,
    required Map<String, dynamic>? payload,
  }) {
    final parsed = SyncDataset.fromRemoteName(dataset);
    if (parsed == null) return true;
    // Legacy per-book direction identities can contain source URLs, query
    // strings, or tokens. Retain remote records for compatibility, but never
    // publish them from the reader-settings scope.
    if (parsed == SyncDataset.readerSettings &&
        recordId.startsWith('image_direction:')) {
      return true;
    }
    if ((parsed == SyncDataset.bookSources || parsed == SyncDataset.books) &&
        payload?['sync_schema'] != 1) {
      return true;
    }
    if (_containsPrivateSourceUid(recordId) ||
        _containsPrivateSourceUid(entityKey) ||
        _containsPrivateSourceUid('${payload?['book_uid'] ?? ''}')) {
      return true;
    }
    return false;
  }

  static bool hasPrivateSourceIdentity(String? value) {
    final candidate = value?.trim() ?? '';
    if (candidate.isEmpty) return false;
    final uri = Uri.tryParse(candidate);
    if (uri != null && uri.hasScheme) return true;
    return candidate.contains('?') ||
        candidate.contains('#') ||
        candidate.contains('@');
  }

  static bool _containsPrivateSourceUid(String value) {
    if (!value.startsWith('source:')) return false;
    final identity = value.substring('source:'.length);
    return identity.contains('://') ||
        identity.contains('?') ||
        identity.contains('#') ||
        identity.contains('@');
  }

  static Set<String> enabledRemoteNames(WebDavSyncScope scope) => {
    for (final dataset in SyncDataset.values)
      if (isEnabled(dataset, scope)) dataset.remoteName,
  };
}
