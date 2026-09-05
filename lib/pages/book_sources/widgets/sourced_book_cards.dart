import 'package:flutter/material.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/generated_book_cover.dart';
import 'package:xxread/widgets/source_cover_image.dart';

import 'book_source_text_normalizer.dart';
import '../models/sourced_book.dart';

BoxDecoration bookSourcePanelDecoration(
  BuildContext context, {
  double radius = 16,
  bool stronger = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final palette = PageStyleHelper.palette(context);
  final isMaterial3Style =
      Theme.of(context).extension<UiStyleThemeExtension>()?.isMaterial3Style ??
      false;
  return BoxDecoration(
    color: isMaterial3Style
        ? (stronger ? scheme.surfaceContainer : scheme.surfaceContainerLow)
        : (stronger ? palette.cardStrong : palette.card),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: scheme.outline.withValues(alpha: isMaterial3Style ? 0.22 : 0.12),
      width: 0.8,
    ),
  );
}

class SourcedBookCard extends StatelessWidget {
  const SourcedBookCard({
    super.key,
    required this.result,
    required this.onTap,
    this.editorial = false,
    this.width = 132,
  });

  final SourcedBook result;
  final VoidCallback onTap;
  final bool editorial;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(editorial ? 8 : 18),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(editorial ? 2 : 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(editorial ? 6 : 14),
                    child: _SourcedBookCover(book: result.book),
                  ),
                ),
                SizedBox(height: editorial ? 10 : 8),
                Text(
                  result.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: editorial
                      ? Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        )
                      : const TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: editorial ? 4 : 2),
                Text(
                  result.book.author.isEmpty
                      ? result.source.name
                      : result.book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: editorial ? null : 12,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SourcedBookListTile extends StatelessWidget {
  const SourcedBookListTile({
    super.key,
    required this.result,
    required this.onTap,
    this.editorial = false,
    this.onSourceTap,
  });

  final SourcedBook result;
  final VoidCallback onTap;
  final bool editorial;
  final VoidCallback? onSourceTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final book = result.book;
    final description = normalizeBookSourceDescription(book.description);
    if (editorial) {
      return _EditorialSourcedBookListTile(
        result: result,
        description: description,
        onTap: onTap,
        onSourceTap: onSourceTap,
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: bookSourcePanelDecoration(context, radius: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SourcedBookCoverThumb(book: book),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      book.author,
                      result.source.name,
                    ].where((item) => item.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _EditorialSourcedBookListTile extends StatelessWidget {
  const _EditorialSourcedBookListTile({
    required this.result,
    required this.description,
    required this.onTap,
    this.onSourceTap,
  });

  final SourcedBook result;
  final String description;
  final VoidCallback onTap;
  final VoidCallback? onSourceTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final book = result.book;
    final metadata = [
      book.author,
      result.source.name,
    ].where((item) => item.isNotEmpty).join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 2, 0),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SourcedBookCoverThumb(
                    book: book,
                    width: 78,
                    height: 108,
                    radius: 6,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          if (onSourceTap != null)
                            Row(
                              children: [
                                if (book.author.isNotEmpty)
                                  Flexible(
                                    child: Text(
                                      book.author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall,
                                    ),
                                  ),
                                Flexible(
                                  child: TextButton(
                                    onPressed: onSourceTap,
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(44, 44),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                    ),
                                    child: Text(
                                      '${result.source.name} ›',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else if (metadata.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            Text(
                              metadata,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.25,
                              ),
                            ),
                          ],
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.82),
                                height: 1.45,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 22,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(
                key: const Key('sourcedBookEditorialDivider'),
                height: 1,
                thickness: 0.7,
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SourcedBookCoverThumb extends StatelessWidget {
  const SourcedBookCoverThumb({
    super.key,
    required this.book,
    this.width = 58,
    this.height = 78,
    this.radius = 10,
  });

  final BookSourceBook book;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: width,
      height: height,
      child: GeneratedBookCover(title: book.title, author: book.author),
    );
    if (book.coverUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SourceCoverImage(
        url: book.coverUrl!,
        headers: book.coverHeaders,
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        fallback: fallback,
      ),
    );
  }
}

class _SourcedBookCover extends StatelessWidget {
  const _SourcedBookCover({required this.book});

  final BookSourceBook book;

  @override
  Widget build(BuildContext context) {
    final fallback = GeneratedBookCover(title: book.title, author: book.author);
    if (book.coverUrl == null) return fallback;
    return SourceCoverImage(
      url: book.coverUrl!,
      headers: book.coverHeaders,
      fit: BoxFit.cover,
      cacheWidth: (132 * MediaQuery.devicePixelRatioOf(context)).round(),
      fallback: fallback,
    );
  }
}

class SourcedBookShelfCompletionView extends StatelessWidget {
  const SourcedBookShelfCompletionView({
    super.key,
    required this.book,
    required this.reduceMotion,
    required this.message,
    this.alreadyAdded = false,
  });

  final BookSourceBook book;
  final bool reduceMotion;
  final String message;
  final bool alreadyAdded;

  @override
  Widget build(BuildContext context) => Padding(
    key: Key(
      alreadyAdded
          ? 'bookSourceAlreadyAddedCompletion'
          : 'bookSourceAddedCompletion',
    ),
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (alreadyAdded)
          Icon(
            Icons.info_outline_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          )
        else
          _BookDropsOntoShelf(book: book, animate: !reduceMotion),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _BookDropsOntoShelf extends StatelessWidget {
  const _BookDropsOntoShelf({required this.book, required this.animate});

  final BookSourceBook book;
  final bool animate;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: const Key('bookSourceShelfDropAnimation'),
    tween: Tween(begin: 0, end: 1),
    duration: animate ? const Duration(milliseconds: 320) : Duration.zero,
    curve: Curves.easeOutBack,
    builder: (context, value, child) => SizedBox(
      width: 86,
      height: 92,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(
            top: 0,
            child: Transform.translate(
              offset: Offset(0, value * 11),
              child: child,
            ),
          ),
          Positioned(
            left: 4,
            right: 4,
            bottom: 3,
            child: Container(
              height: 7,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(99),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.shadow.withValues(alpha: 0.18),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    child: SourcedBookCoverThumb(book: book),
  );
}
