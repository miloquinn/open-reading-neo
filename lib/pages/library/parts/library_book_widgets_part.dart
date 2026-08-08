// 文件说明：书库封面、选择指示器与筛选按钮等纯视图组件。
// 技术要点：LibraryPage 私有实现拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

class _BookCoverItem extends StatelessWidget {
  final Book book;
  final GlobalKey coverKey;
  final Future<void> Function() onTap;
  final VoidCallback onLongPress;
  final bool selectionActive;
  final bool selected;

  const _BookCoverItem({
    required this.book,
    required this.coverKey,
    required this.onTap,
    required this.onLongPress,
    required this.selectionActive,
    required this.selected,
  });

  /// 封面下方文本区域高度与间距，网格计算格子高度时复用。
  static const double textHeight = 44.0;
  static const double gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final progress = book.progress;

    return InkWell(
      onTap: () => unawaited(onTap()),
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final isMaterial3Style =
              theme.extension<UiStyleThemeExtension>()?.isMaterial3Style ??
              false;
          final coverWidth = constraints.maxWidth;
          final targetCoverHeight = coverWidth * 3 / 2;
          final availableCoverHeight = math.max(
            0.0,
            constraints.maxHeight - textHeight - gap,
          );
          final coverHeight = math.min(availableCoverHeight, targetCoverHeight);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 书籍封面区域 - 2:3比例，但不超过可用高度
              Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  key: coverKey,
                  width: coverWidth,
                  height: coverHeight,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(
                            alpha: isMaterial3Style ? 0.08 : 0.15,
                          ),
                          blurRadius: isMaterial3Style ? 6 : 8,
                          offset: const Offset(0, 3),
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        // 封面图片或默认图标
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _gridCoverArt(context, book),
                        ),
                        if (selectionActive)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: _BookSelectionIndicator(selected: selected),
                          ),
                        if (book.isOnline)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                context.l10n.bookSourceOnlineBadge,
                                style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        // 阅读进度指示器（仅在有进度时显示）
                        if (progress > 0)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 4,
                              decoration: BoxDecoration(
                                color: scheme.scrim.withValues(
                                  alpha: isMaterial3Style ? 0.2 : 0.3,
                                ),
                                borderRadius: const BorderRadius.only(
                                  bottomLeft: Radius.circular(12),
                                  bottomRight: Radius.circular(12),
                                ),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: progress.clamp(0.0, 1.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    borderRadius: const BorderRadius.only(
                                      bottomLeft: Radius.circular(12),
                                      bottomRight: Radius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // "在读"标签
                        if (book.currentPage > 0)
                          Positioned(
                            top: 6,
                            left: book.isOnline ? 6 : null,
                            right: book.isOnline ? null : 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: isMaterial3Style
                                    ? null
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.2,
                                          ),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                              ),
                              child: Text(
                                context.l10n.libraryReadingBadge,
                                style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: gap),
              // 书籍信息区域 - 固定高度
              Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: coverWidth,
                  height: textHeight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 书名：超长时自动滚动
                        Expanded(
                          child: ScrollingText(
                            text: book.title,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  height: 1.15,
                                ),
                            duration: const Duration(seconds: 5),
                            pauseDuration: const Duration(milliseconds: 1200),
                          ),
                        ),
                        const SizedBox(height: 2),
                        // 作者信息
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.78,
                                ),
                                fontSize: 11,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BookSelectionIndicator extends StatelessWidget {
  const _BookSelectionIndicator({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : scheme.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary)
          : null,
    );
  }
}

/// 网格封面画面（真实封面或默认设计），不带圆角：
/// 由格子里的 ClipRRect 或打开动画的飞行图层负责裁剪。
Widget _gridCoverArt(BuildContext context, Book book) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isMaterial3Style =
      theme.extension<UiStyleThemeExtension>()?.isMaterial3Style ?? false;
  if (!kIsWeb &&
      book.coverImagePath != null &&
      book.coverImagePath!.isNotEmpty) {
    // 有封面图片时，直接显示真实的书籍封面
    // cacheWidth 限制解码分辨率：网格封面显示宽度不会超过 ~240 逻辑像素，
    // 全分辨率解码原图会占用大量内存并在滑动切页时造成掉帧。
    // 打开动画复用同一 provider，展开时无需重新解码即可立即上屏。
    final cacheWidth = (240 * MediaQuery.of(context).devicePixelRatio).round();
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ColoredBox(
        color: scheme.surface.withValues(alpha: isMaterial3Style ? 0.2 : 0.12),
        child: Image.file(
          File(book.coverImagePath!),
          fit: LayoutHelper.bookCoverFit,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            return _gridDefaultCover(context, book);
          },
        ),
      ),
    );
  }
  final sourceCover = _sourceCoverUrl(book);
  if (sourceCover != null) {
    return SourceCoverImage(
      url: sourceCover,
      headers: _sourceCoverHeaders(book),
      width: double.infinity,
      height: double.infinity,
      fit: LayoutHelper.bookCoverFit,
      cacheWidth: (240 * MediaQuery.of(context).devicePixelRatio).round(),
      fallback: _gridDefaultCover(context, book),
    );
  }
  // 没有封面图片时，显示默认封面设计
  return _gridDefaultCover(context, book);
}

/// 构建默认封面设计
Widget _gridDefaultCover(BuildContext context, Book book) {
  return GeneratedBookCover(title: book.title, author: book.author);
}

Uri? _sourceCoverUrl(Book book) {
  final raw = book.sourceBookJson;
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final value = decoded['coverUrl'];
    if (value is! String || value.isEmpty) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    if (parsed.hasAuthority) return parsed;
    final sourceRaw = book.sourceJson;
    if (sourceRaw == null || sourceRaw.isEmpty) return null;
    final source = jsonDecode(sourceRaw);
    if (source is! Map || source['apiBaseUrl'] is! String) return null;
    final baseUri = Uri.tryParse(source['apiBaseUrl'] as String);
    return baseUri?.resolveUri(parsed);
  } catch (_) {
    return null;
  }
}

Map<String, String> _sourceCoverHeaders(Book book) {
  final raw = book.sourceBookJson;
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final headers = decoded['coverHeaders'];
    if (headers is! Map) return const {};
    return {
      for (final entry in headers.entries)
        '${entry.key}': '${entry.value ?? ''}',
    };
  } catch (_) {
    return const {};
  }
}

/// 顶栏筛选按钮：点击时把自身在屏幕上的位置传给菜单定位。
class _LibraryFilterButton extends StatelessWidget {
  final bool active;
  final BoxDecoration Function(bool active) decoration;
  final Color iconColor;
  final Future<void> Function(Rect anchor) onTapWithRect;

  const _LibraryFilterButton({
    required this.active,
    required this.decoration,
    required this.iconColor,
    required this.onTapWithRect,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.libraryFilterTooltip,
      child: Builder(
        builder: (buttonContext) => InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            final box = buttonContext.findRenderObject()! as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            unawaited(onTapWithRect(rect));
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: decoration(active),
            child: Icon(
              active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
