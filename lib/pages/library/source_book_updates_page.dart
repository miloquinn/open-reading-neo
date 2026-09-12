import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_shelf_service.dart';
import '../../book_sources/services/source_chapter_state.dart';
import '../../models/book.dart';
import '../../services/books/book_dao.dart';
import '../../services/library/download_task_controller.dart';
import '../../services/sync/book_sync_identity.dart';
import '../../services/sync/webdav_sync_controller.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import 'download_tasks_page.dart';

String sourceUpdateResultText(
  BuildContext context,
  SourceUpdateResult result, {
  SourceUpdateMode? mode,
}) {
  final l10n = context.l10n;
  return switch (result.status) {
    SourceUpdateStatus.noChanges =>
      mode == SourceUpdateMode.refreshDownloadedChapters
          ? l10n.bookSourceDownloadedUnchanged
          : l10n.bookSourceNoNewChapters,
    SourceUpdateStatus.updated => l10n.bookSourceUpdateSummary(
      result.addedChapterCount,
      result.refreshedChapterCount,
    ),
    SourceUpdateStatus.baselineUnknown => l10n.bookSourceBaselineUnknown,
    SourceUpdateStatus.needsConfirmation => l10n.bookSourceMappingChanged,
    SourceUpdateStatus.conflicts => l10n.bookSourceContentConflicts,
  };
}

class SourceBookUpdatesPage extends StatefulWidget {
  const SourceBookUpdatesPage({
    super.key,
    required this.book,
    this.shelfService,
    this.bookLoader,
    this.bookUid,
  });

  final Book book;
  final BookSourceShelfService? shelfService;
  final Future<Book?> Function(int id)? bookLoader;
  final String? bookUid;

  @override
  State<SourceBookUpdatesPage> createState() => _SourceBookUpdatesPageState();
}

class _SourceBookUpdatesPageState extends State<SourceBookUpdatesPage> {
  late Book _book = widget.book;
  late final _service = widget.shelfService ?? BookSourceShelfService();
  final _store = const SourceChapterStateStore();
  SourceChapterState? _sourceState;
  SourceUpdateResult? _result;
  String? _message;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    if (widget.shelfService == null) _service.close();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final id = _book.id;
      if (id != null) {
        _book = await (widget.bookLoader ?? BookDao().getBookById)(id) ?? _book;
      }
      final state = await _store.load(_book);
      if (!mounted) return;
      setState(() {
        _sourceState = state;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = context.l10n.bookSourceUpdateFailed;
        _busy = false;
      });
    }
  }

  Future<String> _uid() async => widget.bookUid ?? await stableBookUid(_book);

  void _requestSync() {
    final sync = context.read<WebDavSyncController?>();
    sync?.requestAutomaticSync(immediate: true);
  }

  Future<void> _update(SourceUpdateMode mode) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final uid = await _uid();
      if (!mounted) return;
      final controller = context.read<DownloadTaskController>();
      // The queue owns its service so leaving this page cannot close an
      // in-flight source connection.
      final taskId = controller.enqueueSourceUpdate(
        shelfBook: _book,
        mode: mode,
        shelfService: widget.shelfService ?? BookSourceShelfService(),
        closeServiceWhenDone: widget.shelfService == null,
        bookUid: uid,
      );
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BookDownloadTaskDialog(taskId: taskId),
      );
      if (!mounted) return;
      final task = controller.taskById(taskId);
      _result = task?.sourceUpdateResult;
      if (_result != null) {
        _book = _result!.book;
        _message = sourceUpdateResultText(context, _result!, mode: mode);
        _requestSync();
      } else if (task?.state == DownloadTaskState.failed) {
        _message = context.l10n.bookSourceUpdateFailed;
      } else {
        _message = context.l10n.downloadRunningInBackground;
      }
    } catch (_) {
      if (mounted) _message = context.l10n.bookSourceUpdateFailed;
    }
    if (mounted) await _reload();
  }

  Future<void> _chooseBoundary() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final catalog = await _service.sourceChaptersFor(_book);
      if (!mounted) return;
      BookSourceChapter? selected;
      final boundary = await showDialog<BookSourceChapter>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, update) => AlertDialog(
            title: Text(context.l10n.bookSourceSelectBoundary),
            content: SizedBox(
              width: 460,
              height: 420,
              child: Column(
                children: [
                  Text(context.l10n.bookSourceBoundaryHelp),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: catalog.length,
                      itemBuilder: (_, index) {
                        final chapter = catalog[index];
                        return ListTile(
                          title: Text(chapter.title),
                          selected: selected?.id == chapter.id,
                          trailing: selected?.id == chapter.id
                              ? const Icon(Icons.check_rounded)
                              : null,
                          onTap: () => update(() => selected = chapter),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(dialogContext, selected),
                child: Text(context.l10n.confirm),
              ),
            ],
          ),
        ),
      );
      if (boundary != null) {
        await _service.establishTrackingBaseline(
          shelfBook: _book,
          sourceChapters: catalog,
          lastDownloadedChapterId: boundary.id,
          mappingConfirmed: true,
          bookUid: await _uid(),
        );
        if (mounted) {
          _result = null;
          _message = context.l10n.bookSourceTrackingEstablished;
          _requestSync();
        }
      }
    } catch (_) {
      if (mounted) _message = context.l10n.bookSourceUpdateFailed;
    }
    if (mounted) await _reload();
  }

  Future<void> _compare(SourceContentConflict conflict) async {
    setState(() => _busy = true);
    try {
      final texts = await Future.wait([
        _store.readAsset(_book, conflict.localAsset),
        _store.readAsset(_book, conflict.sourceAsset),
        conflict.baselineAsset.isEmpty
            ? Future.value(context.l10n.bookSourceBaselineUnknown)
            : _store.readAsset(_book, conflict.baselineAsset),
      ]);
      if (!mounted) return;
      final choice = await showDialog<SourceConflictResolution>(
        context: context,
        builder: (dialogContext) => DefaultTabController(
          length: 3,
          child: AlertDialog(
            title: Text(context.l10n.bookSourceCompareVersions),
            content: SizedBox(
              width: 680,
              height: 420,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabs: [
                      Tab(text: context.l10n.bookSourceLocalVersion),
                      Tab(text: context.l10n.bookSourceRemoteVersion),
                      Tab(text: context.l10n.bookSourceBaselineVersion),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        for (final text in texts)
                          SingleChildScrollView(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(text),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  SourceConflictResolution.useSource,
                ),
                child: Text(context.l10n.bookSourceUseRemote),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  SourceConflictResolution.keepLocal,
                ),
                child: Text(context.l10n.bookSourceKeepLocal),
              ),
            ],
          ),
        ),
      );
      if (choice != null) {
        _result = await _service.resolveSourceConflict(
          shelfBook: _book,
          conflictId: conflict.id,
          resolution: choice,
        );
        _book = _result!.book;
        if (mounted) _requestSync();
      }
    } catch (_) {
      if (mounted) _message = context.l10n.bookSourceUpdateFailed;
    }
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final conflicts =
        _sourceState?.conflicts.where((c) => c.resolution == null).toList() ??
        [];
    final needsBoundary =
        _sourceState == null ||
        _sourceState!.catalogChapterIds.isEmpty ||
        _sourceState!.sourceId != _book.sourceId ||
        _sourceState!.sourceBookId != _book.sourceBookId ||
        _result?.status == SourceUpdateStatus.baselineUnknown ||
        _result?.status == SourceUpdateStatus.needsConfirmation;
    return FloatingSubpageScaffold(
      title: l10n.bookSourceTrackUpdatesTitle,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(_book.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(l10n.bookSourceTrackUpdatesBody),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _update(SourceUpdateMode.appendNewChapters),
            icon: const Icon(Icons.update_rounded),
            label: Text(l10n.bookSourceCheckNewChapters),
          ),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _update(SourceUpdateMode.refreshDownloadedChapters),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(l10n.bookSourceRefreshDownloaded),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_message!),
            ),
          if (needsBoundary) ...[
            const SizedBox(height: 16),
            Text(l10n.bookSourceBaselineUnknown),
            TextButton(
              onPressed: _busy ? null : _chooseBoundary,
              child: Text(l10n.bookSourceSelectBoundary),
            ),
          ],
          if (conflicts.isNotEmpty) ...[
            const Divider(height: 32),
            Text(
              l10n.bookSourceContentConflicts,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(l10n.bookSourceContentConflictBody),
            for (final conflict in conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _sourceState!.chapters
                          .where(
                            (chapter) =>
                                chapter.sourceChapterId ==
                                conflict.sourceChapterId,
                          )
                          .map((chapter) => chapter.title)
                          .firstOrNull ??
                      conflict.sourceChapterId,
                ),
                trailing: const Icon(Icons.compare_arrows_rounded),
                subtitle: Text(l10n.bookSourceCompareVersions),
                onTap: _busy ? null : () => _compare(conflict),
              ),
          ],
        ],
      ),
    );
  }
}
