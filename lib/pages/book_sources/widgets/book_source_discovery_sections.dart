import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_cards.dart';

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
          IconButton.filledTonal(
            key: const Key('bookSourceDiscoverLayoutToggle'),
            tooltip: layoutTooltip,
            onPressed: onToggleLayout,
            icon: Icon(
              standardLayout
                  ? Icons.view_list_rounded
                  : Icons.dashboard_outlined,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            key: const Key('bookSourceSearchEntry'),
            tooltip: searchTooltip,
            onPressed: onSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: managementTooltip,
            onPressed: onManage,
            icon: const Icon(Icons.tune_rounded),
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
          SegmentedButton<BookSourcesSection>(
            showSelectedIcon: false,
            segments: sections
                .map(
                  (section) => switch (section) {
                    BookSourcesSection.recommended => ButtonSegment(
                      value: section,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(recommendedLabel),
                    ),
                    BookSourcesSection.categories => ButtonSegment(
                      value: section,
                      icon: const Icon(Icons.category_outlined),
                      label: Text(categoriesLabel),
                    ),
                    BookSourcesSection.latest => ButtonSegment(
                      value: section,
                      icon: const Icon(Icons.update_rounded),
                      label: Text(latestLabel),
                    ),
                  },
                )
                .toList(growable: false),
            selected: {selectedSection},
            onSelectionChanged: (selection) {
              if (selection.isNotEmpty) onSectionSelected(selection.first);
            },
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
              side: WidgetStatePropertyAll(
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
          ),
      ],
    );
  }
}

class _SourceScope extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final itemCount = sources.length + (includeAll ? 1 : 0);
    return SizedBox(
      key: const Key('bookSourceDiscoverScopeControl'),
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (includeAll && index == 0) {
            return ChoiceChip(
              key: const Key('bookSourceDiscoverScopeAll'),
              selected: selectedSourceId == null,
              label: Text(allLabel),
              onSelected: (_) => onSelected(null),
            );
          }
          final source = sources[index - (includeAll ? 1 : 0)];
          return ChoiceChip(
            key: Key('bookSourceDiscoverScope-${source.id}'),
            selected: selectedSourceId == source.id,
            label: Text(source.name),
            onSelected: (_) => onSelected(source.id),
          );
        },
      ),
    );
  }
}

class BookSourceDiscoveryShelfSection extends StatelessWidget {
  final BookSourceDiscoveryShelf shelf;
  final FutureOr<void> Function(SourcedBook book) onBookTap;

  const BookSourceDiscoveryShelfSection({
    super.key,
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  shelf.source.name,
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 242,
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
                  onTap: () => onBookTap(result),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BookSourceCategoryChannels extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final ordered = [
      selectedCategory,
      ...categories.where((category) => category != selectedCategory),
    ];
    return SizedBox(
      key: const Key('bookSourceDiscoveryChannels'),
      height: 42,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ordered.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = ordered[index];
                return ChoiceChip(
                  key: Key(
                    'bookSourceDiscoveryChannel-${category.source.id}-${category.id}',
                  ),
                  selected: category == selectedCategory,
                  label: Text(category.name),
                  onSelected: (_) => onSelected(category),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          ActionChip(
            key: const Key('bookSourceCategoryPickerButton'),
            avatar: const Icon(Icons.tune_rounded, size: 18),
            label: Text(pickerLabel),
            onPressed: onOpenPicker,
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
