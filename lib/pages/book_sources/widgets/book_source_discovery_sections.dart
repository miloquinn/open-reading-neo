import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_cards.dart';

import 'book_source_pill.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/glass_control_surface.dart';

class BookSourceRailHeader extends StatelessWidget {
  final String title;
  final bool standardLayout;
  final String layoutTooltip;
  final String searchTooltip;
  final String managementTooltip;
  final VoidCallback onToggleLayout;
  final VoidCallback onSearch;
  final VoidCallback onManage;

  const BookSourceRailHeader({
    super.key,
    required this.title,
    required this.standardLayout,
    required this.layoutTooltip,
    required this.searchTooltip,
    required this.managementTooltip,
    required this.onToggleLayout,
    required this.onSearch,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 36,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          FloatingSubpageAction(
            key: const Key('bookSourceDiscoverLayoutToggle'),
            tooltip: layoutTooltip,
            onPressed: onToggleLayout,
            icon: standardLayout
                ? Icons.view_list_rounded
                : Icons.dashboard_outlined,
          ),
          const SizedBox(width: 8),
          FloatingSubpageAction(
            key: const Key('bookSourceSearchEntry'),
            tooltip: searchTooltip,
            onPressed: onSearch,
            icon: Icons.search_rounded,
          ),
          const SizedBox(width: 8),
          FloatingSubpageAction(
            tooltip: managementTooltip,
            onPressed: onManage,
            icon: Icons.tune_rounded,
          ),
        ],
      ),
    );
  }
}

class BookSourceDiscoveryControls extends StatelessWidget {
  final List<RegisteredBookSource> sources;
  final bool includeAllSources;
  final String? selectedSourceId;
  final List<BookSourcesSection> sections;
  final BookSourcesSection selectedSection;
  final String allLabel;
  final String recommendedLabel;
  final String categoriesLabel;
  final String latestLabel;
  final ValueChanged<String?> onSourceSelected;
  final ValueChanged<BookSourcesSection> onSectionSelected;

  const BookSourceDiscoveryControls({
    super.key,
    required this.sources,
    required this.includeAllSources,
    required this.selectedSourceId,
    required this.sections,
    required this.selectedSection,
    required this.allLabel,
    required this.recommendedLabel,
    required this.categoriesLabel,
    required this.latestLabel,
    required this.onSourceSelected,
    required this.onSectionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sources.isNotEmpty)
          _SourceScope(
            sources: sources,
            includeAll: includeAllSources,
            selectedSourceId: selectedSourceId,
            allLabel: allLabel,
            onSelected: onSourceSelected,
          ),
        if (sources.isNotEmpty && sections.length > 1)
          const SizedBox(height: 8),
        if (sections.length > 1)
          _SectionTrack(
            sections: sections,
            selectedSection: selectedSection,
            labels: {
              BookSourcesSection.recommended: recommendedLabel,
              BookSourcesSection.categories: categoriesLabel,
              BookSourcesSection.latest: latestLabel,
            },
            onSelected: onSectionSelected,
          ),
      ],
    );
  }
}

class _SourceScope extends StatefulWidget {
  final List<RegisteredBookSource> sources;
  final bool includeAll;
  final String? selectedSourceId;
  final String allLabel;
  final ValueChanged<String?> onSelected;

  const _SourceScope({
    required this.sources,
    required this.includeAll,
    required this.selectedSourceId,
    required this.allLabel,
    required this.onSelected,
  });

  @override
  State<_SourceScope> createState() => _SourceScopeState();
}

class _SourceScopeState extends State<_SourceScope> {
  final Map<String, GlobalKey> _itemKeys = {};
  final ItemScrollController _itemScrollController = ItemScrollController();

  GlobalKey _itemKey(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void didUpdateWidget(covariant _SourceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSourceId != widget.selectedSourceId) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_revealSelected()),
      );
    }
  }

  Future<void> _revealSelected() async {
    if (!mounted) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selectedId = widget.selectedSourceId ?? '__all__';
    final selectedContext = _itemKeys[selectedId]?.currentContext;
    if (selectedContext == null && _itemScrollController.isAttached) {
      final matchingSourceIndex = widget.sources.indexWhere(
        (source) => source.id == widget.selectedSourceId,
      );
      final sourceIndex = widget.selectedSourceId == null
          ? 0
          : matchingSourceIndex < 0
          ? -1
          : matchingSourceIndex + (widget.includeAll ? 1 : 0);
      if (sourceIndex >= 0 && itemCount > 1) {
        if (reduceMotion) {
          _itemScrollController.jumpTo(index: sourceIndex, alignment: 0.5);
        } else {
          await _itemScrollController.scrollTo(
            index: sourceIndex,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        }
      }
      return;
    }
    if (selectedContext == null || !selectedContext.mounted) return;
    final renderObject = selectedContext.findRenderObject();
    if (renderObject == null) return;
    final position = Scrollable.of(selectedContext).position;
    final leading = RenderAbstractViewport.of(
      renderObject,
    ).getOffsetToReveal(renderObject, 0).offset;
    await position.ensureVisible(
      renderObject,
      alignmentPolicy: leading < position.pixels
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  int get itemCount => widget.sources.length + (widget.includeAll ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final textHeight = MediaQuery.textScalerOf(context).scale(14) * 1.35;
    return SizedBox(
      key: const Key('bookSourceDiscoverScopeControl'),
      height: math.max(48.0, textHeight + 22),
      child: ScrollablePositionedList.separated(
        itemScrollController: _itemScrollController,
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (widget.includeAll && index == 0) {
            final selected = widget.selectedSourceId == null;
            return KeyedSubtree(
              key: const Key('bookSourceDiscoverScopeAll'),
              child: BookSourcePill(
                key: _itemKey('__all__'),
                label: widget.allLabel,
                selected: selected,
                onPressed: () => widget.onSelected(null),
              ),
            );
          }
          final source = widget.sources[index - (widget.includeAll ? 1 : 0)];
          final selected = widget.selectedSourceId == source.id;
          return KeyedSubtree(
            key: Key('bookSourceDiscoverScope-${source.id}'),
            child: BookSourcePill(
              key: _itemKey(source.id),
              label: source.name,
              selected: selected,
              onPressed: () => widget.onSelected(source.id),
            ),
          );
        },
      ),
    );
  }
}

class _SectionTrack extends StatelessWidget {
  const _SectionTrack({
    required this.sections,
    required this.selectedSection,
    required this.labels,
    required this.onSelected,
  });

  final List<BookSourcesSection> sections;
  final BookSourcesSection selectedSection;
  final Map<BookSourcesSection, String> labels;
  final ValueChanged<BookSourcesSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final glassEnabled = GlassControlSurface.usesGlass(context);
    final selectedIndex = sections
        .indexOf(selectedSection)
        .clamp(0, sections.length - 1);
    final alignmentX = sections.length == 1
        ? 0.0
        : (-1 + (selectedIndex * 2 / (sections.length - 1))).toDouble();
    final textHeight = MediaQuery.textScalerOf(context).scale(14) * 1.35;
    final height = math.max(52.0, textHeight + 26);
    return GlassControlSurface(
      key: const Key('bookSourceSectionTrackSurface'),
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Stack(
            children: [
              AnimatedAlign(
                key: const Key('bookSourceSectionSelectionPill'),
                alignment: AlignmentDirectional(alignmentX, 0),
                duration: reduceMotion
                    ? Duration.zero
                    : BookSourcePill.selectionDuration,
                curve: Curves.easeOutCubic,
                child: FractionallySizedBox(
                  widthFactor: 1 / sections.length,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: glassEnabled ? null : scheme.surface,
                      gradient: glassEnabled
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                scheme.surface.withValues(alpha: 0.76),
                                scheme.primaryContainer.withValues(alpha: 0.48),
                              ],
                            )
                          : null,
                      shadows: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.08),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final section in sections)
                    Expanded(
                      child: BookSourcePill(
                        label: labels[section]!,
                        enableSurface: false,
                        selected: section == selectedSection,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        maxLabelWidth: null,
                        backgroundColor: Colors.transparent,
                        selectedBackgroundColor: Colors.transparent,
                        foregroundColor: scheme.onSurface,
                        selectedForegroundColor: scheme.primary,
                        onPressed: () => onSelected(section),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BookSourceDiscoveryShelfSection extends StatelessWidget {
  final Widget? sourceActions;
  final BookSourceDiscoveryShelf shelf;
  final FutureOr<void> Function(SourcedBook book) onBookTap;

  const BookSourceDiscoveryShelfSection({
    super.key,
    this.sourceActions,
    required this.shelf,
    required this.onBookTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shelf.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  shelf.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?sourceActions,
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : 420.0;
              final cardWidth = ((availableWidth - 24) / 3)
                  .clamp(100.0, 132.0)
                  .toDouble();
              final scaler = MediaQuery.textScalerOf(context);
              final railHeight = math.max(
                242.0,
                (cardWidth * 1.5) +
                    (scaler.scale(16) * 1.2) +
                    (scaler.scale(14) * 1.2) +
                    24,
              );
              return SizedBox(
                height: railHeight,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: shelf.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final result = SourcedBook(
                      source: shelf.source,
                      book: shelf.items[index],
                    );
                    return SourcedBookCard(
                      result: result,
                      editorial: true,
                      width: cardWidth,
                      onTap: () => onBookTap(result),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class BookSourceCategoryChannels extends StatefulWidget {
  final List<SourcedBookCategory> categories;
  final SourcedBookCategory selectedCategory;
  final String pickerLabel;
  final ValueChanged<SourcedBookCategory> onSelected;
  final VoidCallback onOpenPicker;

  const BookSourceCategoryChannels({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.pickerLabel,
    required this.onSelected,
    required this.onOpenPicker,
  });

  @override
  State<BookSourceCategoryChannels> createState() =>
      _BookSourceCategoryChannelsState();
}

class _BookSourceCategoryChannelsState
    extends State<BookSourceCategoryChannels> {
  final Map<String, GlobalKey> _itemKeys = {};
  final ItemScrollController _itemScrollController = ItemScrollController();

  String _categoryKey(SourcedBookCategory category) =>
      '${category.source.id}\u0000${category.id}';

  GlobalKey _itemKey(SourcedBookCategory category) =>
      _itemKeys.putIfAbsent(_categoryKey(category), GlobalKey.new);

  @override
  void didUpdateWidget(covariant BookSourceCategoryChannels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedCategory != widget.selectedCategory) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_revealSelected()),
      );
    }
  }

  Future<void> _revealSelected() async {
    if (!mounted) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final categoryKey = _categoryKey(widget.selectedCategory);
    final selectedContext = _itemKeys[categoryKey]?.currentContext;
    if (selectedContext == null && _itemScrollController.isAttached) {
      final selectedIndex = widget.categories.indexOf(widget.selectedCategory);
      if (selectedIndex >= 0 && widget.categories.length > 1) {
        if (reduceMotion) {
          _itemScrollController.jumpTo(index: selectedIndex, alignment: 0.5);
        } else {
          await _itemScrollController.scrollTo(
            index: selectedIndex,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        }
      }
      return;
    }
    if (selectedContext == null || !selectedContext.mounted) return;
    final renderObject = selectedContext.findRenderObject();
    if (renderObject == null) return;
    final position = Scrollable.of(selectedContext).position;
    final leading = RenderAbstractViewport.of(
      renderObject,
    ).getOffsetToReveal(renderObject, 0).offset;
    await position.ensureVisible(
      renderObject,
      alignmentPolicy: leading < position.pixels
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textHeight = MediaQuery.textScalerOf(context).scale(14) * 1.35;
    return SizedBox(
      key: const Key('bookSourceDiscoveryChannels'),
      height: math.max(48.0, textHeight + 22),
      child: Row(
        children: [
          Expanded(
            child: ScrollablePositionedList.separated(
              itemScrollController: _itemScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: widget.categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = widget.categories[index];
                final selected = category == widget.selectedCategory;
                return KeyedSubtree(
                  key: Key(
                    'bookSourceDiscoveryChannel-${category.source.id}-${category.id}',
                  ),
                  child: BookSourcePill(
                    key: _itemKey(category),
                    label: category.name,
                    selected: selected,
                    onPressed: () => widget.onSelected(category),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          BookSourcePill(
            key: const Key('bookSourceCategoryPickerButton'),
            icon: Icons.grid_view_rounded,
            label: widget.pickerLabel,
            selected: false,
            maxLabelWidth: 96,
            onPressed: widget.onOpenPicker,
          ),
        ],
      ),
    );
  }
}

class BookSourceMessageCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final FutureOr<void> Function()? onAction;

  const BookSourceMessageCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: bookSourcePanelDecoration(context, radius: 22),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => onAction!(),
              icon: const Icon(Icons.tune_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
