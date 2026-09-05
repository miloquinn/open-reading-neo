import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/sync_dataset_catalog.dart';
import 'package:xxread/services/sync/sync_models.dart';

void main() {
  test('notes are available but remain opt-in for existing users', () {
    expect(SyncDataset.notes.remoteName, 'notes');
    expect(SyncDatasetCatalog.isSupported(SyncDataset.notes), isTrue);
    expect(
      SyncDatasetCatalog.isEnabled(
        SyncDataset.notes,
        const WebDavSyncScope(notes: true),
      ),
      isTrue,
    );
    expect(const WebDavSyncScope().notes, isFalse);
    expect(WebDavSyncScope.fromJson(const <String, dynamic>{}).notes, isFalse);
  });

  test('supported datasets still follow the user scope', () {
    const scope = WebDavSyncScope(bookSources: false, bookmarks: false);
    expect(SyncDatasetCatalog.isEnabled(SyncDataset.books, scope), isTrue);
    expect(
      SyncDatasetCatalog.isEnabled(SyncDataset.bookSources, scope),
      isFalse,
    );
    expect(SyncDatasetCatalog.isEnabled(SyncDataset.bookmarks, scope), isFalse);
  });

  test('book source scope is enabled by default and survives JSON storage', () {
    const scope = WebDavSyncScope();
    expect(scope.bookSources, isTrue);
    expect(WebDavSyncScope.fromJson(scope.toJson()).bookSources, isTrue);
    expect(
      WebDavSyncScope.fromJson(const <String, dynamic>{}).bookSources,
      isTrue,
    );
  });

  test('reader settings default on while replacement rules remain opt-in', () {
    const scope = WebDavSyncScope();
    expect(scope.readerSettings, isTrue);
    expect(scope.replaceRules, isFalse);
    expect(
      SyncDatasetCatalog.isEnabled(SyncDataset.readerSettings, scope),
      isTrue,
    );
    expect(
      SyncDatasetCatalog.isEnabled(SyncDataset.readerThemes, scope),
      isTrue,
    );
    expect(
      SyncDatasetCatalog.isEnabled(SyncDataset.replaceRules, scope),
      isFalse,
    );

    final restored = WebDavSyncScope.fromJson(scope.toJson());
    expect(restored.readerSettings, isTrue);
    expect(restored.replaceRules, isFalse);
  });

  test('legacy per-book direction records are never publishable', () {
    expect(
      SyncDatasetCatalog.isRecordPublishable(
        dataset: 'reader_settings',
        recordId: 'font_size',
        scope: const WebDavSyncScope(),
      ),
      isTrue,
    );
    expect(
      SyncDatasetCatalog.isRecordPublishable(
        dataset: 'reader_settings',
        recordId: 'image_direction:legacy-token-record',
        scope: const WebDavSyncScope(),
      ),
      isFalse,
    );
  });

  test('legacy source payloads and private source identities are blocked', () {
    const scope = WebDavSyncScope();
    expect(
      SyncDatasetCatalog.isRecordPublishable(
        dataset: 'book_sources',
        recordId: 'source-1',
        entityKey: 'source-1',
        payload: const {'header': 'Bearer secret'},
        scope: scope,
      ),
      isFalse,
    );
    expect(
      SyncDatasetCatalog.isRecordPublishable(
        dataset: 'books',
        recordId: 'source:public-source:book-1',
        entityKey: 'source:public-source:book-1',
        payload: const {'sync_schema': 1},
        scope: scope,
      ),
      isTrue,
    );
    expect(
      SyncDatasetCatalog.isRecordPublishable(
        dataset: 'notes',
        recordId: 'note-1',
        entityKey: 'source:https://example.org/catalog?token=secret:book-1',
        payload: const {
          'book_uid': 'source:https://example.org/catalog?token=secret:book-1',
        },
        scope: const WebDavSyncScope(notes: true),
      ),
      isFalse,
    );
  });
}
