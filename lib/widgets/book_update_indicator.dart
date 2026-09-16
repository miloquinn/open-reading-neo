import 'package:flutter/material.dart';

import '../book_sources/models/source_book_update_info.dart';
import '../models/book.dart';
import '../utils/localization_extension.dart';

/// A small, consistent update marker in every library cover layout.
class BookUpdateIndicator extends StatelessWidget {
  const BookUpdateIndicator({
    super.key,
    required this.book,
    required this.child,
  });

  final Book book;
  final Widget child;

  static bool hasUpdate(Book book) =>
      SourceBookUpdateInfo.fromBook(book).hasNewChapters;

  @override
  Widget build(BuildContext context) {
    if (!hasUpdate(book)) return child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 4,
          right: 4,
          child: Tooltip(
            message: context.l10n.bookSourceUpdatesAvailable,
            child: Container(
              key: const ValueKey('book-cover-update-indicator'),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
              child: Icon(
                Icons.update_rounded,
                size: 11,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
