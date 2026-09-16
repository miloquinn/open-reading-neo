import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/library/library_event_bus_service.dart';
import 'package:intl/intl.dart';

import '../../book_sources/models/source_book_update_info.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_change_service.dart';
import '../../book_sources/services/book_source_registry.dart';
import '../../book_sources/services/book_source_shelf_service.dart';
import '../../book_sources/services/source_book_update_service.dart';
import '../../models/book.dart';
import '../../services/books/book_dao.dart';
import '../../utils/localization_extension.dart';
import '../book_sources/book_source_change_page.dart';
import 'source_book_updates_page.dart';

String sourceBookCheckStatusText(
  BuildContext context,
  SourceBookUpdateInfo info,
) => switch (info.status) {
  SourceBookCheckStatus.unchecked => context.l10n.bookSourceNotChecked,
  SourceBookCheckStatus.current => context.l10n.bookSourceUpToDate,
  SourceBookCheckStatus.available => context.l10n.bookSourceUpdatesAvailable,
  SourceBookCheckStatus.needsMapping => context.l10n.bookSourceNeedsMapping,
  SourceBookCheckStatus.failed => context.l10n.bookSourceUpdateFailed,
};

/// Shared by library details and both readers so the same book always exposes
/// the same binding, status, and continuation actions.
class SourceBookStatusCard extends StatefulWidget {
  const SourceBookStatusCard({
    super.key,
    required this.book,
    this.onBookChanged,
    this.checkBook,
    this.bookLoader,
    this.allowSourceBinding = true,
  });
  final bool allowSourceBinding;
  final Future<Book?> Function(int)? bookLoader;
  final Book book;
  final ValueChanged<Book>? onBookChanged;
  final Future<Book> Function(Book)? checkBook;

  @override
  State<SourceBookStatusCard> createState() => _SourceBookStatusCardState();
}

class _SourceBookStatusCardState extends State<SourceBookStatusCard> {
  late Book _book = widget.book;
  bool _busy = false;
  bool _failed = false;
  int _reloadRevision = 0;
  StreamSubscription<void>? _librarySubscription;

  @override
  void initState() {
    super.initState();
    _librarySubscription = LibraryEventBus().stream.listen(
      (_) => unawaited(_refreshBook()),
    );
  }

  @override
  void dispose() {
    _reloadRevision++;
    unawaited(_librarySubscription?.cancel());
    super.dispose();
  }

  Future<void> _refreshBook() async {
    if (_busy || _book.id == null) return;
    final revision = ++_reloadRevision;
    try {
      final book = await (widget.bookLoader ?? BookDao().getBookById)(
        _book.id!,
      );
      if (!mounted || _busy || revision != _reloadRevision || book == null) {
        return;
      }
      final changed =
          book.sourceBookJson != _book.sourceBookJson ||
          book.contentHash != _book.contentHash ||
          book.coverImagePath != _book.coverImagePath;
      setState(() => _book = book);
      if (changed) widget.onBookChanged?.call(book);
    } catch (_) {
      /* Preserve last known status if storage is unavailable. */
    }
  }

  @override
  void didUpdateWidget(covariant SourceBookStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book && !_busy) _book = widget.book;
  }

  Future<void> _run(Future<Book?> Function() action) async {
    _reloadRevision++;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final book = await action();
      if (mounted && book != null) {
        setState(() => _book = book);
        widget.onBookChanged?.call(book);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Book?> _bind() async {
    final shelf = BookSourceShelfService();
    try {
      final binding = _book.hasSourceBinding ? shelf.bindingFrom(_book) : null;
      final result = await Navigator.of(context).push<BookSourceChangeResult>(
        MaterialPageRoute(
          builder: (_) => BookSourceChangePage(
            currentSource: binding?.source,
            currentBook:
                binding?.book ??
                BookSourceBook(
                  id: 'local:${_book.id}',
                  title: _book.title,
                  author: _book.author,
                  description: '',
                  categories: const [],
                ),
            shelfBook: _book,
            sourcesFuture: BookSourceRegistry().loadRunnableInBackground(),
          ),
        ),
      );
      return result?.shelfBook;
    } finally {
      shelf.close();
    }
  }

  Future<Book?> _continue() async {
    final originalHash = _book.contentHash;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SourceBookUpdatesPage(book: _book)),
    );
    if (!mounted) return null;
    final book = await BookDao().getBookById(_book.id!);
    if (book == null) return null;
    if (book.contentHash != originalHash &&
        SourceBookUpdateInfo.fromBook(book).status ==
            SourceBookCheckStatus.current) {
      return book;
    }
    return SourceBookUpdateService().check(book);
  }

  void _help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        _book.hasSourceBinding
            ? context.l10n.bookSourceUpdates
            : context.l10n.bookSourceBindSource,
      ),
      content: Text(
        _book.hasSourceBinding
            ? context.l10n.bookSourceUpdateHelp
            : context.l10n.bookSourceBindHelp,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.confirm),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_book.id == null ||
        (!_book.hasSourceBinding && _book.format.toLowerCase() != 'txt')) {
      return const SizedBox.shrink();
    }
    final info = SourceBookUpdateInfo.fromBook(_book);
    final bound = _book.hasSourceBinding;
    String date(DateTime value) => DateFormat.yMd(
      Localizations.localeOf(context).toString(),
    ).add_Hm().format(value.toLocal());
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    bound
                        ? context.l10n.bookSourceUpdates
                        : context.l10n.bookSourceBindSource,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: bound
                      ? context.l10n.bookSourceUpdates
                      : context.l10n.bookSourceBindSource,
                  onPressed: _help,
                  icon: const Icon(Icons.info_outline_rounded, size: 20),
                ),
              ],
            ),
            if (bound) ...[
              Text(
                _failed
                    ? context.l10n.bookSourceUpdateFailed
                    : sourceBookCheckStatusText(context, info),
                style: TextStyle(
                  color: info.status == SourceBookCheckStatus.available
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              if (info.latestChapter?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.l10n.bookSourceLatestChapterLabel(
                      info.latestChapter!,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                info.updatedAt == null
                    ? context.l10n.bookSourceUpdateTimeUnknown
                    : context.l10n.bookSourceLastUpdated(date(info.updatedAt!)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (info.checkedAt != null)
                Text(
                  context.l10n.bookSourceLastChecked(date(info.checkedAt!)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ] else
              Text(context.l10n.bookSourceBindHelp),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (bound)
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () =>
                                (widget.checkBook ??
                                SourceBookUpdateService().check)(_book),
                          ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.bookSourceCheckUpdates),
                  ),
                if (bound &&
                    !_book.isOnline &&
                    _book.format.toLowerCase() == 'txt')
                  TextButton(
                    onPressed: _busy ? null : () => _run(_continue),
                    child: Text(
                      info.status == SourceBookCheckStatus.needsMapping
                          ? context.l10n.bookSourceSelectBoundary
                          : context.l10n.bookSourceContinueUpdate,
                    ),
                  ),
                // Online readers retain their own source-switch route, which also
                // replaces the active reader. Local books keep the original text.
                if (!_book.isOnline && widget.allowSourceBinding)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _run(_bind),
                    icon: Icon(
                      bound ? Icons.swap_horiz_rounded : Icons.link_rounded,
                    ),
                    label: Text(
                      bound
                          ? context.l10n.bookSourceChangeSourceTitle
                          : context.l10n.bookSourceBindSource,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
