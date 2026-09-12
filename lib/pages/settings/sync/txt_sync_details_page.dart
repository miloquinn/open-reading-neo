import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/book.dart';
import '../../../services/books/book_dao.dart';
import '../../../services/sync/book_content_sync_service.dart';
import '../../../services/sync/webdav_sync_controller.dart';
import '../../../utils/localization_extension.dart';
import '../../../widgets/floating_subpage_scaffold.dart';
import '../../../widgets/side_toast.dart';
import 'book_file_sync_page.dart';

class TxtSyncDetailsPage extends StatefulWidget {
  const TxtSyncDetailsPage({super.key});

  @override
  State<TxtSyncDetailsPage> createState() => _TxtSyncDetailsPageState();
}

class _TxtSyncDetailsPageState extends State<TxtSyncDetailsPage> {
  List<BookContentState> _states = const [];
  Map<int, Book> _books = const {};
  bool _loading = true;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sync = context.read<WebDavSyncController>();
    try {
      await sync.refreshTextStates();
      final states = sync.textStates;
      final books = await BookDao().getAllBooks();
      if (!mounted) return;
      setState(() {
        _states = states;
        _books = {
          for (final book in books)
            if (book.id != null) book.id!: book,
        };
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (_) {
      if (mounted) {
        showSideToast(
          context,
          context.l10n.cloudSyncFailed,
          kind: SideToastKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compare(BookContentState state) async {
    final sync = context.read<WebDavSyncController>();
    final conflicts = await sync.contentSyncService.listConflicts(
      bookUid: state.bookUid,
    );
    if (!mounted || conflicts.isEmpty) return;
    final conflict = conflicts.first;
    final previews = await _differencePreviews(
      conflict.localSnapshotPath,
      conflict.remoteSnapshotPath,
    );
    if (!mounted) return;
    final choice = await showDialog<BookContentConflictChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.cloudSyncCompare),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.cloudSyncBothKept),
                const SizedBox(height: 12),
                Text(
                  context.l10n.cloudSyncKeepLocal,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText(previews[0]),
                const Divider(height: 24),
                Text(
                  context.l10n.cloudSyncUseRemote,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText(previews[1]),
                const SizedBox(height: 16),
                Text(
                  context.l10n.cloudSyncPreviewLimited,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, BookContentConflictChoice.useRemote),
            child: Text(context.l10n.cloudSyncUseRemote),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, BookContentConflictChoice.keepLocal),
            child: Text(context.l10n.cloudSyncKeepLocal),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await sync.contentSyncService.resolveConflict(conflict.id, choice);
    if (sync.autoSync) sync.requestAutomaticSync(immediate: true);
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncBooks,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: floatingSubpagePadding(
            context,
            left: 20,
            top: 20,
            right: 20,
            bottom: 20,
          ),
          children: [
            Text(l10n.cloudSyncBooksHint),
            if (_states.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l10n.cloudSyncTextLocationHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.library_books_outlined),
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BookFileSyncPage(),
                        ),
                      );
                      if (mounted) await _load();
                    },
              label: Text(l10n.cloudSyncManageBooks),
            ),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_failed)
              TextButton(onPressed: _load, child: Text(l10n.cloudSyncFailed)),
            if (!_loading && !_failed && _states.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(l10n.cloudSyncNoBooks),
              ),
            for (final state in _states)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _books[state.localBookId]?.title ?? state.bookUid,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(txtSyncStatusText(context, state.status)),
                      Text(l10n.cloudSyncReadableStorage),
                      const SizedBox(height: 8),
                      SelectableText(
                        '${l10n.cloudSyncTextLocation}: ${sync.rootPath ?? ''}/${state.remotePath}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.cloudSyncParticipate),
                        value: state.enabled,
                        onChanged: _busy
                            ? null
                            : (enabled) => _run(() async {
                                await sync.contentSyncService.setEnabled(
                                  state.bookUid,
                                  enabled,
                                );
                                if (enabled) {
                                  sync.requestAutomaticSync(immediate: true);
                                }
                              }),
                      ),
                      if (state.status == BookContentSyncStatus.conflict)
                        FilledButton.tonal(
                          onPressed: _busy
                              ? null
                              : () => _run(() => _compare(state)),
                          child: Text(l10n.cloudSyncCompare),
                        ),
                      if (state.status == BookContentSyncStatus.updateAvailable)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final applied = await sync.contentSyncService
                                      .applyPendingRemote(state.bookUid);
                                  if (!applied && context.mounted) {
                                    showSideToast(
                                      context,
                                      context.l10n.cloudSyncCloseReaderToUpdate,
                                    );
                                  }
                                }),
                          child: Text(l10n.cloudSyncApplyUpdate),
                        ),
                      if (state.status == BookContentSyncStatus.failed ||
                          state.status == BookContentSyncStatus.pending)
                        TextButton(
                          onPressed: _busy || !sync.scope.bookFiles
                              ? null
                              : () => _run(() => sync.synchronizeTextFiles()),
                          child: Text(l10n.webDavSyncNow),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String txtSyncStatusText(BuildContext context, BookContentSyncStatus status) {
  final l10n = context.l10n;
  return switch (status) {
    BookContentSyncStatus.localOnly => l10n.cloudSyncLocalOnly,
    BookContentSyncStatus.paused => l10n.cloudSyncPaused,
    BookContentSyncStatus.pending => l10n.cloudSyncPending,
    BookContentSyncStatus.syncing => l10n.webDavSyncing,
    BookContentSyncStatus.synced => l10n.cloudSyncCurrent,
    BookContentSyncStatus.updateAvailable => l10n.cloudSyncApplyUpdate,
    BookContentSyncStatus.conflict => l10n.cloudSyncConflict,
    BookContentSyncStatus.failed => l10n.cloudSyncFailed,
  };
}

Future<List<String>> _differencePreviews(String local, String remote) async {
  final a = await File(local).open();
  RandomAccessFile? b;
  try {
    b = await File(remote).open();
    var offset = 0;
    var difference = 0;
    while (true) {
      final chunks = await Future.wait([a.read(8192), b.read(8192)]);
      final left = chunks[0];
      final right = chunks[1];
      final common = left.length < right.length ? left.length : right.length;
      var i = 0;
      while (i < common && left[i] == right[i]) {
        i++;
      }
      if (i < common || left.length != right.length || common == 0) {
        difference = offset + i;
        break;
      }
      offset += common;
    }
    final start = (difference - 512).clamp(0, difference);
    final previews = <String>[];
    for (final file in [a, b]) {
      final length = await file.length();
      await file.setPosition(start.clamp(0, length));
      final bytes = await file.read(4000);
      previews.add(
        '${start > 0 ? '…\n' : ''}${utf8.decode(bytes, allowMalformed: true)}'
        '${start + bytes.length < length ? '\n…' : ''}',
      );
    }
    return previews;
  } finally {
    await a.close();
    await b?.close();
  }
}
