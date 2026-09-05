import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_registry.dart';
import 'book_source_organization_copy.dart';
import 'book_source_organization_sheets.dart';

export 'book_source_organization_copy.dart';
export 'book_source_organization_sheets.dart'
    show
        showBookSourceGroupEditor,
        showBookSourceGroupManager,
        showBookSourceOrganizationGroupPicker;

enum _BookSourceOrganizationAction { groups, details }

/// Compact favorite and organization controls for a book-source row or title.
class BookSourceOrganizationActions extends StatefulWidget {
  const BookSourceOrganizationActions({
    super.key,
    required this.source,
    required this.registry,
    this.onChanged,
    this.onShowDetails,
  });

  final RegisteredBookSource source;
  final BookSourceRegistry registry;
  final VoidCallback? onChanged;
  final VoidCallback? onShowDetails;

  @override
  State<BookSourceOrganizationActions> createState() =>
      _BookSourceOrganizationActionsState();
}

class _BookSourceOrganizationActionsState
    extends State<BookSourceOrganizationActions> {
  late bool _favorite = widget.source.isFavorite;
  bool _savingFavorite = false;

  @override
  void didUpdateWidget(BookSourceOrganizationActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_savingFavorite && oldWidget.source != widget.source) {
      _favorite = widget.source.isFavorite;
    }
  }

  Future<void> _setFavorite(bool value, {bool showNotice = true}) async {
    if (_savingFavorite || value == _favorite) return;
    final previous = _favorite;
    setState(() {
      _favorite = value;
      _savingFavorite = true;
    });
    try {
      await widget.registry.setFavorite(widget.source.id, value);
      if (!mounted) return;
      setState(() => _savingFavorite = false);
      widget.onChanged?.call();
      if (showNotice) _showFavoriteNotice(value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _favorite = previous;
        _savingFavorite = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(BookSourceOrganizationCopy.of(context).saveFailed),
        ),
      );
    }
  }

  void _showFavoriteNotice(bool value) {
    final copy = BookSourceOrganizationCopy.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final registry = widget.registry;
    final sourceId = widget.source.id;
    final onChanged = widget.onChanged;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(value ? copy.favorited : copy.unfavorited),
        action: SnackBarAction(
          label: copy.undo,
          onPressed: () async {
            try {
              await registry.setFavorite(sourceId, !value);
              if (mounted) {
                setState(() {
                  _favorite = !value;
                  _savingFavorite = false;
                });
              }
              onChanged?.call();
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(copy.saveFailed)));
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _selectAction(_BookSourceOrganizationAction action) async {
    switch (action) {
      case _BookSourceOrganizationAction.groups:
        final changed = await showBookSourceGroupEditor(
          context,
          registry: widget.registry,
          sources: [widget.source],
        );
        if (changed) widget.onChanged?.call();
      case _BookSourceOrganizationAction.details:
        widget.onShowDetails?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = BookSourceOrganizationCopy.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('bookSourceFavorite-${widget.source.id}'),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          tooltip: _favorite ? copy.unfavorite : copy.favorite,
          onPressed: _savingFavorite ? null : () => _setFavorite(!_favorite),
          icon: Icon(
            _favorite ? Icons.star_rounded : Icons.star_border_rounded,
            size: 22,
            color: _favorite ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        SizedBox.square(
          dimension: 44,
          child: PopupMenuButton<_BookSourceOrganizationAction>(
            key: ValueKey('bookSourceOrganizationMore-${widget.source.id}'),
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
            tooltip: copy.moreActions,
            onSelected: _selectAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _BookSourceOrganizationAction.groups,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(copy.addToGroups),
                ),
              ),
              if (widget.onShowDetails != null)
                PopupMenuItem(
                  value: _BookSourceOrganizationAction.details,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(copy.sourceDetails),
                  ),
                ),
            ],
            icon: const Icon(Icons.more_horiz_rounded, size: 22),
          ),
        ),
      ],
    );
  }
}
