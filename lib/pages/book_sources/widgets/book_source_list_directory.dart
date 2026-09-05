import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_list_reveal.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_cards.dart';
import 'package:xxread/utils/layout_helper.dart';

import 'book_source_pill.dart';
import '../../../utils/page_style_helper.dart';

class BookSourceListDirectory extends StatelessWidget {
  final TextEditingController searchController;
  final List<BookSourceListChannels> groups;
  final List<BookSourceListChannels> filteredGroups;
  final BookSourcesState state;
  final String searchHint;
  final String clearSearchTooltip;
  final String noMatchesLabel;
  final String resetFiltersLabel;
  final String retryLabel;
  final String Function(int count) channelCountLabel;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final ValueChanged<BookSourceListChannels> onToggleSource;
  final ValueChanged<BookSourceListChannels> onExpandSource;
  final ValueChanged<SourcedBookCategory> onSelectCategory;
  final bool Function(String sourceId) shouldAnimateSource;
  final Widget Function(RegisteredBookSource source)? sourceActionsBuilder;

  const BookSourceListDirectory({
    super.key,
    required this.searchController,
    required this.groups,
    required this.filteredGroups,
    required this.state,
    required this.searchHint,
    required this.clearSearchTooltip,
    required this.noMatchesLabel,
    required this.resetFiltersLabel,
    required this.retryLabel,
    required this.channelCountLabel,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onToggleSource,
    required this.onExpandSource,
    required this.onSelectCategory,
    required this.shouldAnimateSource,
    this.sourceActionsBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final usesTabletLayout = LayoutHelper.usesTabletLayout(context);
    final horizontalPadding = usesTabletLayout
        ? LayoutHelper.tabletPagePadding
        : 16.0;
    final contentMaxWidth = usesTabletLayout ? double.infinity : 1048.0;
    final itemCount = filteredGroups.isEmpty ? 1 : filteredGroups.length;
    final childCount = (itemCount * 2) - 1;
    return SliverMainAxisGroup(
      slivers: [
        PinnedHeaderSliver(
          child: ColoredBox(
            color: PageStyleHelper.palette(context).backgroundStart,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                8,
                horizontalPadding,
                10,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: contentMaxWidth),
                  child: _SearchField(
                    controller: searchController,
                    groups: groups,
                    filteredGroups: filteredGroups,
                    query: state.listSourceQuery,
                    hint: searchHint,
                    clearTooltip: clearSearchTooltip,
                    onChanged: onQueryChanged,
                    onClear: onClearQuery,
                    onSubmitted: () {
                      if (filteredGroups.isNotEmpty) {
                        onExpandSource(filteredGroups.first);
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            32,
          ),
          sliver: SliverList(
            key: const Key('bookSourceListLayoutDirectory'),
            delegate: SliverChildBuilderDelegate(
              (context, childIndex) {
                if (childIndex.isOdd) return const SizedBox(height: 10);
                final index = childIndex ~/ 2;
                final child = switch (index) {
                  _ when filteredGroups.isEmpty => _EmptySearch(
                    label: noMatchesLabel,
                    resetLabel: resetFiltersLabel,
                    onReset: onClearQuery,
                  ),
                  _ => BookSourceListReveal(
                    key: Key(
                      'bookSourceListReveal-${filteredGroups[index].source.id}',
                    ),
                    animate: shouldAnimateSource(
                      filteredGroups[index].source.id,
                    ),
                    order: index,
                    child: _sourceEntry(filteredGroups[index]),
                  ),
                };
                return Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: contentMaxWidth),
                    child: child,
                  ),
                );
              },
              childCount: childCount,
              addAutomaticKeepAlives: false,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sourceEntry(BookSourceListChannels group) => _SourceEntry(
    key: ValueKey('bookSourceListEntry-${group.source.id}'),
    group: group,
    expanded: state.expandedListSourceId == group.source.id,
    loading: state.loadingListChannelSources.contains(group.source.id),
    loaded: state.listChannelsBySource.containsKey(group.source.id),
    error: state.listChannelErrors[group.source.id],
    retryLabel: retryLabel,
    channelCountLabel: channelCountLabel,
    onToggle: () => onToggleSource(group),
    onRetry: () => onExpandSource(group),
    onSelectCategory: onSelectCategory,
    actions: sourceActionsBuilder?.call(group.source),
  );
}

class BookSourceListSelectionHeader extends StatelessWidget {
  final SourcedBookCategory category;
  final String changeLabel;
  final VoidCallback onChange;
  final Widget? actions;

  const BookSourceListSelectionHeader({
    super.key,
    required this.category,
    required this.changeLabel,
    required this.onChange,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('bookSourceListSelectionHeader'),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: const CircleBorder(),
            ),
            child: Icon(
              Icons.rss_feed_rounded,
              color: scheme.onPrimaryContainer,
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ?actions,
          BookSourcePill(
            key: const Key('bookSourceListChangeChannel'),
            label: changeLabel,
            selected: false,
            icon: Icons.swap_horiz_rounded,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            maxLabelWidth: 88,
            onPressed: onChange,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final List<BookSourceListChannels> groups;
  final List<BookSourceListChannels> filteredGroups;
  final String query;
  final String hint;
  final String clearTooltip;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onSubmitted;

  const _SearchField({
    required this.controller,
    required this.groups,
    required this.filteredGroups,
    required this.query,
    required this.hint,
    required this.clearTooltip,
    required this.onChanged,
    required this.onClear,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      key: const Key('bookSourceListSourceSearch'),
      controller: controller,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: (_) => onSubmitted(),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.manage_search_rounded),
        suffixIconConstraints: const BoxConstraints(minHeight: 48),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${filteredGroups.length}/${groups.length}',
              key: const Key('bookSourceListSearchCount'),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (query.isNotEmpty)
              IconButton(
                key: const Key('bookSourceListSourceSearchClear'),
                tooltip: clearTooltip,
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 20),
              )
            else
              const SizedBox(width: 16),
          ],
        ),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
    );
  }
}

class _EmptySearch extends StatelessWidget {
  final String label;
  final String resetLabel;
  final VoidCallback onReset;

  const _EmptySearch({
    required this.label,
    required this.resetLabel,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('bookSourceListSourceSearchEmpty'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: bookSourcePanelDecoration(context, radius: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 34, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onReset, child: Text(resetLabel)),
        ],
      ),
    );
  }
}

class _SourceEntry extends StatefulWidget {
  final Widget? actions;
  final BookSourceListChannels group;
  final bool expanded;
  final bool loading;
  final bool loaded;
  final Object? error;
  final String retryLabel;
  final String Function(int count) channelCountLabel;
  final VoidCallback onToggle;
  final VoidCallback onRetry;
  final ValueChanged<SourcedBookCategory> onSelectCategory;

  const _SourceEntry({
    super.key,
    this.actions,
    required this.group,
    required this.expanded,
    required this.loading,
    required this.loaded,
    required this.error,
    required this.retryLabel,
    required this.channelCountLabel,
    required this.onToggle,
    required this.onRetry,
    required this.onSelectCategory,
  });

  @override
  State<_SourceEntry> createState() => _SourceEntryState();
}

class _SourceEntryState extends State<_SourceEntry>
    with TickerProviderStateMixin {
  AnimationController? _expansionController;
  bool _contentVisible = false;

  @override
  void initState() {
    super.initState();
    _contentVisible = widget.expanded;
  }

  @override
  void didUpdateWidget(covariant _SourceEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _disposeExpansionController();
      _contentVisible = widget.expanded;
      return;
    }
    if (widget.expanded) {
      _contentVisible = true;
      _ensureExpansionController().forward();
    } else {
      final controller = _expansionController;
      if (controller == null) {
        _contentVisible = false;
        return;
      }
      controller.reverse();
    }
  }

  AnimationController _ensureExpansionController() {
    return _expansionController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 180),
    )..addStatusListener(_handleExpansionStatus);
  }

  void _handleExpansionStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || widget.expanded || !mounted) {
      return;
    }
    setState(() {
      _contentVisible = false;
      _disposeExpansionController();
    });
  }

  void _disposeExpansionController() {
    _expansionController
      ?..removeStatusListener(_handleExpansionStatus)
      ..dispose();
    _expansionController = null;
  }

  @override
  void dispose() {
    _disposeExpansionController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final controller = _expansionController;
    return Container(
      key: Key('bookSourceListSource-${widget.group.source.id}'),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('bookSourceListSourceToggle-${widget.group.source.id}'),
              borderRadius: BorderRadius.circular(12),
              onTap: widget.onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: ShapeDecoration(
                        color: scheme.primaryContainer,
                        shape: const CircleBorder(),
                      ),
                      child: Icon(
                        Icons.rss_feed_rounded,
                        color: scheme.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.group.source.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.loaded
                                ? widget.channelCountLabel(
                                    widget.group.channels.length,
                                  )
                                : widget.group.source.apiBaseUrl.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ?widget.actions,
                    AnimatedRotation(
                      turns: widget.expanded ? 0.5 : 0,
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_contentVisible)
            _buildExpandedTransition(
              context,
              controller: controller,
              reduceMotion: reduceMotion,
            ),
        ],
      ),
    );
  }

  Widget _buildExpandedTransition(
    BuildContext context, {
    required AnimationController? controller,
    required bool reduceMotion,
  }) {
    final child = _ExpandedSourceBody(
      loading: widget.loading,
      error: widget.error,
      group: widget.group,
      retryLabel: widget.retryLabel,
      onRetry: widget.onRetry,
      onSelectCategory: widget.onSelectCategory,
    );
    if (reduceMotion || controller == null) return child;
    final animation = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return ClipRect(
      child: SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.035),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ExpandedSourceBody extends StatelessWidget {
  const _ExpandedSourceBody({
    required this.loading,
    required this.error,
    required this.group,
    required this.retryLabel,
    required this.onRetry,
    required this.onSelectCategory,
  });

  static const int _lazyChannelThreshold = 20;
  static const double _lazyChannelHeight = 280;

  final bool loading;
  final Object? error;
  final BookSourceListChannels group;
  final String retryLabel;
  final VoidCallback onRetry;
  final ValueChanged<SourcedBookCategory> onSelectCategory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: scheme.outlineVariant),
        AnimatedSize(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          child: AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.025),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _body(context),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (loading) {
      return const Padding(
        key: ValueKey('loading'),
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (error != null) {
      return Padding(
        key: const ValueKey('error'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error.toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(retryLabel),
            ),
          ],
        ),
      );
    }
    return Padding(
      key: const ValueKey('channels'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: group.channels.length > _lazyChannelThreshold
          ? SizedBox(
              key: const Key('bookSourceListLazyChannels'),
              height: _lazyChannelHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final textTheme = Theme.of(context).textTheme;
                  final baseFontSize = textTheme.labelLarge?.fontSize ?? 14;
                  final scaledFontSize = MediaQuery.textScalerOf(
                    context,
                  ).scale(baseFontSize);
                  final scaleGrowth = (scaledFontSize / baseFontSize - 1).clamp(
                    0.0,
                    2.0,
                  );
                  final targetWidth = 104 + (scaleGrowth * 44);
                  final columnCount =
                      ((constraints.maxWidth + 8) / (targetWidth + 8))
                          .floor()
                          .clamp(1, 8)
                          .toInt();
                  final rowHeight = (scaledFontSize + 26)
                      .clamp(48.0, 76.0)
                      .toDouble();
                  return GridView.builder(
                    primary: false,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(48),
                    itemCount: group.channels.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columnCount,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      mainAxisExtent: rowHeight,
                    ),
                    itemBuilder: (context, index) =>
                        _channelChip(group.channels[index]),
                  );
                },
              ),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final channel in group.channels) _channelChip(channel),
              ],
            ),
    );
  }

  Widget _channelChip(SourcedBookCategory channel) => BookSourcePill(
    key: Key('bookSourceListChannel-${channel.source.id}-${channel.id}'),
    label: channel.name,
    selected: false,
    onPressed: () => onSelectCategory(channel),
  );
}
