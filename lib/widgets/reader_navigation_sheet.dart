import 'dart:async';

import 'package:flutter/material.dart';

import '../core/reader/reader_annotation.dart';
import '../models/book_note.dart';
import '../models/bookmark.dart';
import '../utils/localization_extension.dart';
import '../utils/reader_themes.dart';
import 'open_reading_icons.dart';

class ReaderNavigationChapter {
  const ReaderNavigationChapter({
    required this.title,
    required this.index,
    this.id,
    this.fragment,
    this.depth = 0,
  });

  final String title;
  final int index;
  final String? id;
  final String? fragment;
  final int depth;
}

class ReaderNavigationCatalog {
  ReaderNavigationCatalog(List<ReaderNavigationChapter> chapters)
    : chapters = List.unmodifiable(chapters) {
    final count = chapters.length;
    final positions = List<int>.generate(count, (position) => position);
    final ancestors = <int>[];
    final parentPositions = List<int>.filled(count, -1);
    final hasChildren = List<bool>.filled(count, false);
    final normalizedTitles = List<String>.filled(count, '');
    final searchableTitles = List<String>.filled(count, '');
    final positionsByChapter = <int, List<int>>{};
    final chapterIndexById = <String, int>{};
    final chapterIndexByTitle = <String, int>{};

    for (var position = 0; position < count; position++) {
      final chapter = chapters[position];
      final depth = chapter.depth < 0 ? 0 : chapter.depth;
      while (ancestors.isNotEmpty &&
          (chapters[ancestors.last].depth < 0
                  ? 0
                  : chapters[ancestors.last].depth) >=
              depth) {
        ancestors.removeLast();
      }
      if (ancestors.isNotEmpty) parentPositions[position] = ancestors.last;
      hasChildren[position] =
          position + 1 < count && chapters[position + 1].depth > depth;
      final title = chapter.title.replaceAll(_titleWhitespace, ' ').trim();
      normalizedTitles[position] = title;
      searchableTitles[position] = title.toLowerCase();
      positionsByChapter
          .putIfAbsent(chapter.index, () => <int>[])
          .add(position);
      final id = chapter.id;
      if (id != null && id.isNotEmpty) {
        chapterIndexById.putIfAbsent(id, () => chapter.index);
      }
      if (title.isNotEmpty) {
        chapterIndexByTitle.putIfAbsent(title, () => chapter.index);
      }
      ancestors.add(position);
    }

    this.positions = List.unmodifiable(positions);
    this.parentPositions = List.unmodifiable(parentPositions);
    this.hasChildren = List.unmodifiable(hasChildren);
    this.normalizedTitles = List.unmodifiable(normalizedTitles);
    this.searchableTitles = List.unmodifiable(searchableTitles);
    this.positionsByChapter = Map<int, List<int>>.unmodifiable(
      positionsByChapter.map(
        (index, positions) =>
            MapEntry<int, List<int>>(index, List<int>.unmodifiable(positions)),
      ),
    );
    sortedChapterIndexes = List<int>.unmodifiable(
      positionsByChapter.keys.toList()..sort(),
    );
    this.chapterIndexById = Map.unmodifiable(chapterIndexById);
    this.chapterIndexByTitle = Map.unmodifiable(chapterIndexByTitle);
  }

  static final _titleWhitespace = RegExp(r'\s+');

  final List<ReaderNavigationChapter> chapters;
  late final List<int> positions;
  late final List<int> parentPositions;
  late final List<bool> hasChildren;
  late final List<String> normalizedTitles;
  late final List<String> searchableTitles;
  late final Map<int, List<int>> positionsByChapter;
  late final List<int> sortedChapterIndexes;
  late final Map<String, int> chapterIndexById;
  late final Map<String, int> chapterIndexByTitle;

  int initialPositionForChapter(int chapterIndex) {
    final positions = positionsByChapter[chapterIndex];
    return positions == null || positions.isEmpty
        ? lastPositionBeforeChapter(chapterIndex)
        : positions.first;
  }

  int lastPositionBeforeChapter(int chapterIndex) {
    var low = 0;
    var high = sortedChapterIndexes.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (sortedChapterIndexes[middle] < chapterIndex) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return -1;
    return positionsByChapter[sortedChapterIndexes[low - 1]]!.last;
  }

  int? chapterIndexForTitle(String title) {
    return chapterIndexByTitle[title.replaceAll(_titleWhitespace, ' ').trim()];
  }
}

class ReaderNavigationSheet extends StatefulWidget {
  const ReaderNavigationSheet({
    super.key,
    required this.palette,
    required this.chapters,
    required this.currentChapterIndex,
    required this.bookmarks,
    required this.onChapterSelected,
    required this.onBookmarkSelected,
    required this.onBookmarkDeleted,
    this.onNavigationChapterSelected,
    this.annotations = const [],
    this.onAnnotationSelected,
    this.onAnnotationDeleted,
    this.currentAnchorKey,
    this.currentChapterOffset,
    this.currentChapterText,
    this.currentNavigationPosition,
    this.resolveCurrentNavigationPosition,
    this.catalog,
  });

  final ReaderThemePalette palette;
  final List<ReaderNavigationChapter> chapters;
  final int currentChapterIndex;
  final List<Bookmark> bookmarks;
  final List<BookNote> annotations;
  final String? currentAnchorKey;
  final int? currentChapterOffset;
  final String? currentChapterText;
  final int? currentNavigationPosition;
  // Pinpointing the exact EPUB subsection can require scanning the current
  // chapter's text, which must not run on the frame that opens this sheet.
  // When supplied, it is called once after the first frame instead.
  final int Function()? resolveCurrentNavigationPosition;
  final ReaderNavigationCatalog? catalog;
  final ValueChanged<int> onChapterSelected;
  final ValueChanged<ReaderNavigationChapter>? onNavigationChapterSelected;
  final ValueChanged<Bookmark> onBookmarkSelected;
  final ValueChanged<Bookmark> onBookmarkDeleted;
  final ValueChanged<BookNote>? onAnnotationSelected;
  final ValueChanged<BookNote>? onAnnotationDeleted;

  @override
  State<ReaderNavigationSheet> createState() => _ReaderNavigationSheetState();
}

class _ReaderNavigationSheetState extends State<ReaderNavigationSheet>
    with SingleTickerProviderStateMixin {
  static const _chapterExtent = 64.0;
  static const _treeIndent = 16.0;
  static const _navigationResolveDelay = Duration(milliseconds: 300);

  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _chapterScrollController = ScrollController();
  final Set<int> _collapsedChapterPositions = <int>{};
  String _query = '';

  late ReaderNavigationCatalog _catalog;
  List<int>? _visibleCache;
  int? _resolvedNavigationPosition;
  bool _navigationPositionResolved = false;
  Timer? _navigationResolveTimer;

  @override
  void initState() {
    super.initState();
    assert(
      widget.catalog == null ||
          widget.catalog!.chapters.length == widget.chapters.length,
    );
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChanged);
    _catalog = widget.catalog ?? ReaderNavigationCatalog(widget.chapters);
    _resolvedNavigationPosition = widget.currentNavigationPosition;
    _navigationPositionResolved =
        widget.resolveCurrentNavigationPosition == null;
    _scheduleResolveAndScroll(animate: false);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _searchController.dispose();
    _chapterScrollController.dispose();
    _navigationResolveTimer?.cancel();
    super.dispose();
  }

  void _handleTabChanged() {
    if (!_tabController.indexIsChanging) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ReaderNavigationSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.catalog, widget.catalog) ||
        !identical(oldWidget.chapters, widget.chapters)) {
      _collapsedChapterPositions.clear();
      _catalog = widget.catalog ?? ReaderNavigationCatalog(widget.chapters);
      _visibleCache = null;
    }
    if (oldWidget.currentChapterIndex != widget.currentChapterIndex) {
      _resolvedNavigationPosition = widget.currentNavigationPosition;
      _navigationPositionResolved =
          widget.resolveCurrentNavigationPosition == null;
      _scheduleResolveAndScroll(animate: true);
    }
  }

  void _scheduleResolveAndScroll({required bool animate}) {
    _navigationResolveTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToCurrent(animate: false);
      if (widget.resolveCurrentNavigationPosition == null) return;
      _navigationResolveTimer = Timer(_navigationResolveDelay, () {
        if (mounted) _resolveAndScrollToCurrent(animate: animate);
      });
    });
  }

  void _resolveAndScrollToCurrent({required bool animate}) {
    final resolver = widget.resolveCurrentNavigationPosition;
    if (resolver != null && !_navigationPositionResolved) {
      _resolvedNavigationPosition = resolver();
      _navigationPositionResolved = true;
      if (mounted) setState(() {});
    }
    _scrollToCurrent(animate: animate);
  }

  List<int> get _visibleChapters {
    return _visibleCache ??= _computeVisibleChapters();
  }

  List<int> _computeVisibleChapters() {
    final chapters = _catalog.chapters;
    final normalized = _query.trim().toLowerCase();
    if (normalized.isNotEmpty) {
      final includedPositions = <int>{};
      for (var position = 0; position < chapters.length; position++) {
        if (!_catalog.searchableTitles[position].contains(normalized)) continue;
        var ancestor = position;
        while (ancestor >= 0 && includedPositions.add(ancestor)) {
          ancestor = _catalog.parentPositions[ancestor];
        }
      }
      return Iterable<int>.generate(
        chapters.length,
      ).where(includedPositions.contains).toList(growable: false);
    }
    if (_collapsedChapterPositions.isEmpty) {
      return _catalog.positions;
    }

    final visible = <int>[];
    final collapsedAncestorDepths = <int>[];
    for (var position = 0; position < chapters.length; position++) {
      final depth = chapters[position].depth < 0 ? 0 : chapters[position].depth;
      while (collapsedAncestorDepths.isNotEmpty &&
          collapsedAncestorDepths.last >= depth) {
        collapsedAncestorDepths.removeLast();
      }
      if (collapsedAncestorDepths.isEmpty) visible.add(position);
      if (_collapsedChapterPositions.contains(position)) {
        collapsedAncestorDepths.add(depth);
      }
    }
    return visible;
  }

  int get _currentChapterPosition {
    final suppliedPosition = _resolvedNavigationPosition;
    if (suppliedPosition != null &&
        suppliedPosition >= 0 &&
        suppliedPosition < _catalog.chapters.length) {
      return suppliedPosition;
    }
    final matchingPositions =
        _catalog.positionsByChapter[widget.currentChapterIndex] ??
        const <int>[];
    if (matchingPositions.length <= 1) {
      return matchingPositions.isEmpty ? -1 : matchingPositions.single;
    }
    if (!_navigationPositionResolved) {
      // Picking the exact subsection among several sharing this chapter
      // needs a text scan; use the chapter's first entry until the
      // deferred resolver above refines this.
      return matchingPositions.first;
    }

    final text = widget.currentChapterText;
    final offset = widget.currentChapterOffset;
    if (text == null || offset == null || text.isEmpty) {
      return matchingPositions.first;
    }

    final safeOffset = offset.clamp(0, text.length);
    var selectedPosition = matchingPositions.first;
    var searchFrom = 0;
    for (final position in matchingPositions) {
      final title = _catalog.normalizedTitles[position];
      if (title.isEmpty) continue;
      final titleOffset = text.indexOf(title, searchFrom);
      if (titleOffset < 0) continue;
      searchFrom = titleOffset + title.length;
      if (titleOffset > safeOffset) break;
      selectedPosition = position;
    }
    return selectedPosition;
  }

  void _toggleChapter(int position) {
    setState(() {
      if (!_collapsedChapterPositions.remove(position)) {
        _collapsedChapterPositions.add(position);
      }
      _visibleCache = null;
    });
  }

  void _scrollToCurrent({bool animate = true}) {
    if (!_chapterScrollController.hasClients || _catalog.chapters.isEmpty) {
      return;
    }
    if (_query.isNotEmpty) {
      _searchController.clear();
      setState(() {
        _query = '';
        _visibleCache = null;
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(animate: animate),
      );
      return;
    }
    final currentPosition = _currentChapterPosition;
    if (currentPosition < 0) return;
    var expandedAncestor = false;
    var ancestorPosition = _catalog.parentPositions[currentPosition];
    while (ancestorPosition >= 0) {
      expandedAncestor =
          _collapsedChapterPositions.remove(ancestorPosition) ||
          expandedAncestor;
      ancestorPosition = _catalog.parentPositions[ancestorPosition];
    }
    if (expandedAncestor) {
      setState(() => _visibleCache = null);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(animate: animate),
      );
      return;
    }
    final visiblePosition = _collapsedChapterPositions.isEmpty
        ? currentPosition
        : _visibleChapters.indexWhere(
            (position) => position == currentPosition,
          );
    if (visiblePosition < 0) return;
    final position = _chapterScrollController.position;
    final currentTop = visiblePosition * _chapterExtent;
    final currentBottom = currentTop + _chapterExtent;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + position.viewportDimension;
    if (currentTop >= visibleTop && currentBottom <= visibleBottom) return;
    final rawTarget = currentTop - position.viewportDimension * 0.32;
    final alignedTarget = (rawTarget / _chapterExtent).floor() * _chapterExtent;
    final target = alignedTarget.clamp(0.0, position.maxScrollExtent);
    if (animate) {
      _chapterScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _chapterScrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.palette.toThemeData(
      typography: Theme.of(context).textTheme,
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (themedContext) => Material(
          color: widget.palette.surface,
          surfaceTintColor: Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                _buildDragHandle(),
                _buildHeader(themedContext),
                _buildTabs(themedContext),
                Divider(height: 1, color: widget.palette.border),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildCatalog(themedContext),
                      _DeferredTab(
                        active: _tabController.index == 1,
                        childBuilder: () => _buildBookmarks(themedContext),
                      ),
                      _DeferredTab(
                        active: _tabController.index == 2,
                        childBuilder: () => _buildAnnotations(themedContext),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Container(
      key: const ValueKey('reader-navigation-drag-handle'),
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: widget.palette.secondaryText.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(99),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.readerNavigationTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  context.l10n.readerNavigationPosition(
                    widget.currentChapterIndex + 1,
                    _catalog.chapters.length,
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.palette.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonTooltip),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: widget.palette.controlBar,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: widget.palette.border.withValues(alpha: 0.72),
          ),
        ),
        child: TabBar(
          controller: _tabController,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: widget.palette.controlFill,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: widget.palette.shadow.withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          tabs: [
            Tab(
              height: 42,
              child: _tabLabel(label: context.l10n.readerToolbarTOC),
            ),
            Tab(height: 42, child: _tabLabel(label: context.l10n.bookmarks)),
            Tab(height: 42, child: _tabLabel(label: context.l10n.notes)),
          ],
        ),
      ),
    );
  }

  Widget _tabLabel({required String label}) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }

  Widget _buildCatalog(BuildContext context) {
    final chapters = _visibleChapters;
    final currentPosition = _currentChapterPosition;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() {
                    _query = value;
                    _visibleCache = null;
                  }),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: context.l10n.readerSearchChapters,
                    filled: true,
                    fillColor: widget.palette.controlBar,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: context.l10n.readerBackToCurrentChapter,
                child: TextButton(
                  key: const ValueKey(
                    'reader-navigation-current-chapter-button',
                  ),
                  onPressed: _scrollToCurrent,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(60, 48),
                    backgroundColor: widget.palette.controlFill,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: Text(context.l10n.readerCurrentChapter),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: chapters.isEmpty
              ? _emptyState(
                  context,
                  title: context.l10n.readerNoChapterResults,
                  message: context.l10n.readerNoChapterResultsHint,
                )
              : RawScrollbar(
                  key: const ValueKey('reader-navigation-catalog-scrollbar'),
                  controller: _chapterScrollController,
                  thumbVisibility: true,
                  trackVisibility: true,
                  interactive: true,
                  thickness: 5,
                  radius: const Radius.circular(99),
                  mainAxisMargin: 6,
                  crossAxisMargin: 3,
                  minThumbLength: 44,
                  thumbColor: widget.palette.secondaryText.withValues(
                    alpha: 0.52,
                  ),
                  trackColor: widget.palette.controlBar.withValues(alpha: 0.56),
                  trackBorderColor: Colors.transparent,
                  child: ListView.builder(
                    controller: _chapterScrollController,
                    padding: const EdgeInsets.fromLTRB(8, 2, 20, 20),
                    itemExtent: _chapterExtent,
                    itemCount: chapters.length,
                    itemBuilder: (context, visibleIndex) {
                      final position = chapters[visibleIndex];
                      return _buildChapterTile(
                        context,
                        position,
                        position == currentPosition,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildChapterTile(BuildContext context, int position, bool selected) {
    final chapter = _catalog.chapters[position];
    final normalizedTitle = _catalog.normalizedTitles[position];
    final title = normalizedTitle.isEmpty
        ? context.l10n.readerChapterFallback(chapter.index + 1)
        : normalizedTitle;
    final displayDepth = chapter.depth.clamp(0, 8);
    final isSearching = _query.trim().isNotEmpty;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: title,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: InkWell(
          onTap: () {
            final onNavigationChapterSelected =
                widget.onNavigationChapterSelected;
            if (onNavigationChapterSelected != null) {
              onNavigationChapterSelected(chapter);
            } else {
              widget.onChapterSelected(chapter.index);
            }
          },
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.only(left: 4, right: 8),
            decoration: BoxDecoration(
              color: selected
                  ? widget.palette.accent.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: selected ? 30 : 0,
                  decoration: BoxDecoration(
                    color: widget.palette.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(width: 8),
                _buildDepthGuides(displayDepth),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? widget.palette.accent
                          : widget.palette.text,
                    ),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  OpenReadingCurrentIcon(
                    size: 20,
                    color: widget.palette.accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n.readerCurrentChapter,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: widget.palette.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (_catalog.hasChildren[position]) ...[
                  const SizedBox(width: 4),
                  _buildTreeControl(
                    context,
                    position: position,
                    selected: selected,
                    enabled: !isSearching,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDepthGuides(int depth) {
    if (depth <= 0) return const SizedBox.shrink();
    return SizedBox(
      width: depth * _treeIndent,
      child: Row(
        children: [
          for (var level = 0; level < depth; level++)
            SizedBox(
              width: _treeIndent,
              child: Center(
                child: Container(
                  width: 1,
                  height: _chapterExtent,
                  color: widget.palette.border.withValues(alpha: 0.62),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTreeControl(
    BuildContext context, {
    required int position,
    required bool selected,
    required bool enabled,
  }) {
    final color = selected
        ? widget.palette.accent
        : widget.palette.secondaryText.withValues(alpha: 0.88);
    assert(_catalog.hasChildren[position]);
    final expanded = !_collapsedChapterPositions.contains(position);
    final localizations = MaterialLocalizations.of(context);
    return SizedBox(
      width: 34,
      height: 42,
      child: Tooltip(
        message: expanded
            ? localizations.expandedIconTapHint
            : localizations.collapsedIconTapHint,
        child: IconButton(
          key: ValueKey(
            'reader-navigation-toggle-${_catalog.chapters[position].index}',
          ),
          onPressed: enabled ? () => _toggleChapter(position) : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 42),
          visualDensity: VisualDensity.compact,
          icon: AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: enabled ? color : color.withValues(alpha: 0.48),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookmarks(BuildContext context) {
    if (widget.bookmarks.isEmpty) {
      return _emptyState(
        context,
        title: context.l10n.readerNoBookmarks,
        message: context.l10n.readerNoBookmarksHint,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: widget.bookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, index) {
        final bookmark = widget.bookmarks[index];
        final current =
            bookmark.anchorKey != null &&
            bookmark.anchorKey == widget.currentAnchorKey;
        return _buildBookmarkTile(context, bookmark, current);
      },
    );
  }

  Widget _buildAnnotations(BuildContext context) {
    final annotations = widget.annotations
        .where((annotation) => annotation.type != readerAnnotationTypeInk)
        .toList(growable: false);
    if (annotations.isEmpty) {
      return _emptyState(
        context,
        title: context.l10n.readerNoAnnotations,
        message: context.l10n.readerNoAnnotationsHint,
      );
    }
    annotations.sort((a, b) {
      final chapter = _annotationChapterPosition(
        a,
      ).compareTo(_annotationChapterPosition(b));
      if (chapter != 0) return chapter;
      return (a.startOffset ?? 0).compareTo(b.startOffset ?? 0);
    });
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: annotations.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, index) =>
          _buildAnnotationTile(context, annotations[index]),
    );
  }

  int _annotationChapterPosition(BookNote annotation) {
    final chapterId = readerAnnotationChapterId(annotation);
    if (chapterId != null) {
      final chapterIndex = _catalog.chapterIndexById[chapterId];
      if (chapterIndex != null) return chapterIndex;
    }
    final chapterTitle = annotation.chapter.trim();
    if (chapterTitle.isNotEmpty) {
      final chapterIndex = _catalog.chapterIndexForTitle(chapterTitle);
      if (chapterIndex != null) return chapterIndex;
    }
    return 0x3fffffff;
  }

  Widget _buildAnnotationTile(BuildContext context, BookNote annotation) {
    final color = readerAnnotationColor(annotation.color, widget.palette);
    final title = annotation.chapter.trim().isEmpty
        ? context.l10n.readerChapterFallback((annotation.pageNumber ?? 0) + 1)
        : annotation.chapter.trim();
    final note = annotation.readerNote?.trim() ?? '';
    final excerpt = note.isNotEmpty
        ? note
        : annotation.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final date = annotation.createTime ?? annotation.updateTime;
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final typeLabel = switch (annotation.type) {
      readerAnnotationTypeUnderline => context.l10n.noteTypeUnderline,
      readerAnnotationTypeNote => context.l10n.noteTypeNote,
      _ => context.l10n.noteTypeHighlight,
    };
    return Material(
      color: widget.palette.controlBar.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: widget.onAnnotationSelected == null
            ? null
            : () => widget.onAnnotationSelected!(annotation),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 54,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          annotation.type == readerAnnotationTypeNote
                              ? Icons.mode_comment_outlined
                              : annotation.type == readerAnnotationTypeUnderline
                              ? Icons.format_underlined_rounded
                              : Icons.auto_awesome_rounded,
                          size: 17,
                          color: color,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    if (excerpt.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        excerpt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: widget.palette.secondaryText,
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 7),
                    Text(
                      '$typeLabel · $dateText',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: widget.palette.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                onSelected: (value) {
                  if (value == 'delete') {
                    widget.onAnnotationDeleted?.call(annotation);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'delete',
                    enabled: widget.onAnnotationDeleted != null,
                    child: Text(
                      MaterialLocalizations.of(context).deleteButtonTooltip,
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

  Widget _buildBookmarkTile(
    BuildContext context,
    Bookmark bookmark,
    bool current,
  ) {
    final chapterNumber =
        (bookmark.chapterIndex ?? bookmark.pageNumber).clamp(0, 1000000) + 1;
    final chapterTitle = bookmark.chapterTitle?.trim().isNotEmpty == true
        ? bookmark.chapterTitle!.trim()
        : context.l10n.readerChapterFallback(chapterNumber);
    final excerpt = bookmark.excerpt?.trim() ?? '';
    final date = bookmark.createDate;
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return Semantics(
      button: true,
      selected: current,
      label: chapterTitle,
      child: Material(
        color: current
            ? widget.palette.accent.withValues(alpha: 0.10)
            : widget.palette.controlBar.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: () => widget.onBookmarkSelected(bookmark),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chapterTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (current)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: widget.palette.accent,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                context.l10n.readerCurrentPosition,
                                style: TextStyle(
                                  color: widget.palette.onAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (excerpt.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: widget.palette.secondaryText,
                                height: 1.45,
                              ),
                        ),
                      ],
                      const SizedBox(height: 7),
                      Text(
                        dateText,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: widget.palette.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Text(
                      MaterialLocalizations.of(context).showMenuTooltip,
                      style: TextStyle(
                        color: widget.palette.secondaryText,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  onSelected: (value) {
                    if (value == 'delete') widget.onBookmarkDeleted(bookmark);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        MaterialLocalizations.of(context).deleteButtonTooltip,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: widget.palette.secondaryText,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeferredTab extends StatelessWidget {
  const _DeferredTab({required this.active, required this.childBuilder});

  final bool active;
  final Widget Function() childBuilder;

  @override
  Widget build(BuildContext context) {
    return active ? childBuilder() : const SizedBox.shrink();
  }
}
