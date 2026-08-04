import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/utils/layout_helper.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';
import 'package:xxread/widgets/source_cover_image.dart';

import 'source_login_page.dart';

/// Low-frequency configuration for online content providers.
///
/// Discovery remains user-facing; adding, enabling and removing providers lives
/// here so technical configuration does not interrupt the book-browsing flow.
class BookSourceManagementPage extends StatefulWidget {
  const BookSourceManagementPage({super.key});

  @override
  State<BookSourceManagementPage> createState() =>
      _BookSourceManagementPageState();
}

class _BookSourceManagementPageState extends State<BookSourceManagementPage> {
  static const int _initialSourceBatchSize = 24;
  static const int _sourceBatchSize = 24;
  static const double _loadMoreExtent = 800;

  final BookSourceRegistry _registry = BookSourceRegistry();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  BookSourceClient? _client;
  SourceImportService? _importService;
  BookSourceImportAnalyzer? _importAnalyzer;

  BookSourceClient get _sourceClient => _client ??= BookSourceClient();
  SourceImportService get _additionalImportService =>
      _importService ??= SourceImportService();
  BookSourceImportAnalyzer get _sourceImportAnalyzer => _importAnalyzer ??=
      BookSourceImportAnalyzer(additionalImporter: _additionalImportService);
  List<RegisteredBookSource> _sources = const [];
  final Set<String> _selectedSourceIds = {};
  bool _loading = true;
  bool _selectionMode = false;
  String _searchQuery = '';
  _BookSourceFilter _filter = _BookSourceFilter.all;
  String? _selectedGroup;
  int _sourceDisplayLimit = _initialSourceBatchSize;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreSourcesIfNeeded);
    unawaited(_loadSources());
  }

  Future<void> _loadSources() async {
    final sources = await _registry.loadInBackground();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loading = false;
      _sourceDisplayLimit = _initialSourceBatchSize;
    });
  }

  void _loadMoreSourcesIfNeeded() {
    if (_loading || !_scrollController.hasClients) return;
    if (!_scrollController.position.isScrollingNotifier.value) return;
    if (_scrollController.position.extentAfter > _loadMoreExtent) return;
    final sourceCount = _visibleSources.length;
    if (_sourceDisplayLimit >= sourceCount) return;
    setState(() {
      final nextLimit = _sourceDisplayLimit + _sourceBatchSize;
      _sourceDisplayLimit = nextLimit < sourceCount ? nextLimit : sourceCount;
    });
  }

  void _updateSourceView(VoidCallback update) {
    setState(() {
      update();
      _sourceDisplayLimit = _initialSourceBatchSize;
    });
    if (_scrollController.hasClients && _scrollController.offset != 0) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_loadMoreSourcesIfNeeded)
      ..dispose();
    _searchController.dispose();
    _client?.close();
    _importService?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var additionalProtocolsEnabled = false;
    try {
      additionalProtocolsEnabled = context
          .watch<AppSettingsNotifier>()
          .additionalSourceProtocolsEnabled;
    } on ProviderNotFoundException {
      // Standalone embeds without app settings retain the default-off state.
    }
    return FloatingSubpageScaffold(
      title: context.l10n.bookSourceManagementTitle,
      actions: [
        FloatingSubpageMenuAction<_BookSourceHeaderAction>(
          key: const Key('bookSourcesToolButton'),
          tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
          icon: Icons.more_horiz_rounded,
          onSelected: (action) {
            switch (action) {
              case _BookSourceHeaderAction.add:
                _showAddSourceDialog();
              case _BookSourceHeaderAction.select:
                setState(() {
                  _selectionMode = !_selectionMode;
                  _selectedSourceIds.clear();
                });
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              key: const Key('bookSourcesAddButton'),
              value: _BookSourceHeaderAction.add,
              child: ListTile(
                leading: const Icon(Icons.add_link_rounded),
                title: Text(context.l10n.bookSourcesAdd),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              key: const Key('bookSourcesSelectionModeButton'),
              value: _BookSourceHeaderAction.select,
              child: ListTile(
                leading: Icon(
                  _selectionMode
                      ? Icons.close_rounded
                      : Icons.checklist_rounded,
                ),
                title: Text(context.l10n.bookSourcesSelect),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: _buildSourceList(additionalProtocolsEnabled, scheme),
        ),
      ),
    );
  }

  Widget _buildSourceList(bool additionalProtocolsEnabled, ColorScheme scheme) {
    final visibleSources = _visibleSources;
    final allOrspSources = visibleSources
        .where((source) => source.sourceProtocol == BookSourceProtocolKind.orsp)
        .toList(growable: false);
    final allAdditionalSources = visibleSources
        .where((source) => source.sourceProtocol != BookSourceProtocolKind.orsp)
        .toList(growable: false);
    final orsp = allOrspSources
        .take(_sourceDisplayLimit)
        .toList(growable: false);
    final remainingLimit = _sourceDisplayLimit - orsp.length;
    final additional = allAdditionalSources
        .take(remainingLimit > 0 ? remainingLimit : 0)
        .toList(growable: false);
    final displayedSourceCount = orsp.length + additional.length;
    return Scrollbar(
      key: const Key('bookSourceManagementScrollbar'),
      controller: _scrollController,
      thumbVisibility: true,
      interactive: true,
      child: CustomScrollView(
        key: const Key('bookSourceManagementList'),
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: FloatingSubpageScaffold.headerExtentOf(context),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    context.l10n.bookSourceManagementSubtitle,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _buildManagementHeader(visibleSources.length),
                  const SizedBox(height: 12),
                  _buildSearchAndFilters(),
                  if (_selectionMode) ...[
                    const SizedBox(height: 12),
                    _buildBulkActions(additionalProtocolsEnabled),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_sources.isEmpty)
            _paddedSliver(_buildNoSourcesCard())
          else if (visibleSources.isEmpty)
            _paddedSliver(_buildNoMatchingSourcesCard())
          else ...[
            if (orsp.isNotEmpty)
              ..._buildSourceGroupSlivers(
                title: context.l10n.bookSourcesProtocolGroupOrsp,
                sources: orsp,
                totalCount: allOrspSources.length,
                additionalProtocolsEnabled: additionalProtocolsEnabled,
              ),
            if (additional.isNotEmpty)
              ..._buildSourceGroupSlivers(
                title: context.l10n.bookSourcesProtocolGroupAdditional,
                sources: additional,
                totalCount: allAdditionalSources.length,
                additionalProtocolsEnabled: additionalProtocolsEnabled,
              ),
            if (displayedSourceCount < visibleSources.length)
              const SliverPadding(
                key: Key('bookSourceManagementLoadingMore'),
                padding: EdgeInsets.symmetric(vertical: 12),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
              ),
          ],
          if (_loading || displayedSourceCount >= visibleSources.length)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
              sliver: SliverToBoxAdapter(child: _buildProtocolCard()),
            ),
        ],
      ),
    );
  }

  Widget _buildManagementHeader(int visibleCount) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.bookSourcesManageTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                context.l10n.bookSourcesVisibleCount(
                  visibleCount,
                  _sources.length,
                ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNoSourcesCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _panelDecoration(radius: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.travel_explore_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.bookSourcesNoSourcesTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.bookSourcesNoSourcesDescription,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<RegisteredBookSource> get _visibleSources {
    final query = _searchQuery.trim().toLowerCase();
    return _sources
        .where((source) {
          final groups = _sourceGroups(source);
          final matchesState = switch (_filter) {
            _BookSourceFilter.all => true,
            _BookSourceFilter.enabled => source.enabled,
            _BookSourceFilter.disabled => !source.enabled,
            _BookSourceFilter.runnable => source.capabilities.isNotEmpty,
            _BookSourceFilter.pending => source.capabilities.isEmpty,
          };
          if (!matchesState) return false;
          final selectedGroup = _selectedGroup;
          if (selectedGroup != null && !groups.contains(selectedGroup)) {
            return false;
          }
          if (query.isEmpty) return true;
          return source.name.toLowerCase().contains(query) ||
              source.description.toLowerCase().contains(query) ||
              source.apiBaseUrl.toString().toLowerCase().contains(query) ||
              groups.any((group) => group.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  List<String> get _availableGroups {
    final groups = <String>{};
    for (final source in _sources) {
      groups.addAll(_sourceGroups(source));
    }
    return groups.toList()..sort();
  }

  List<String> _sourceGroups(RegisteredBookSource source) {
    final raw = source.sourceConfig?['bookSourceGroup'];
    if (raw is! String || raw.trim().isEmpty) return const [];
    return raw
        .split(RegExp(r'[,;，；\n]'))
        .map((group) => group.trim())
        .where((group) => group.isNotEmpty)
        .toList(growable: false);
  }

  Widget _buildSearchAndFilters() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('bookSourceManagementSearchField'),
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: context.l10n.bookSourcesManagementSearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.bookSourcesClearSearch,
                    onPressed: () {
                      _searchController.clear();
                      _updateSourceView(() => _searchQuery = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
            filled: true,
            fillColor: scheme.surfaceContainerLow,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (value) => _updateSourceView(() => _searchQuery = value),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final filter in _BookSourceFilter.values) ...[
                ChoiceChip(
                  key: Key('bookSourceFilter-${filter.name}'),
                  selected: _filter == filter,
                  label: Text(_filterLabel(filter)),
                  onSelected: (_) => _updateSourceView(() => _filter = filter),
                ),
                const SizedBox(width: 8),
              ],
              if (_availableGroups.isNotEmpty)
                ActionChip(
                  key: const Key('bookSourceGroupFilter'),
                  avatar: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(
                    _selectedGroup ?? context.l10n.bookSourcesAllGroups,
                  ),
                  onPressed: _showGroupPicker,
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _filterLabel(_BookSourceFilter filter) => switch (filter) {
    _BookSourceFilter.all => context.l10n.statsRangeAll,
    _BookSourceFilter.enabled => context.l10n.bookSourcesEnabled,
    _BookSourceFilter.disabled => context.l10n.bookSourcesDisabled,
    _BookSourceFilter.runnable => context.l10n.bookSourcesRunnable,
    _BookSourceFilter.pending => context.l10n.bookSourcesPendingCompatibility,
  };

  Future<void> _showGroupPicker() async {
    final groups = _availableGroups;
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) =>
          _BookSourceGroupPicker(groups: groups, selected: _selectedGroup),
    );
    if (!mounted || selected == null) return;
    final normalized = selected.isEmpty ? null : selected;
    if (normalized == _selectedGroup) return;
    _updateSourceView(() => _selectedGroup = normalized);
  }

  Widget _paddedSliver(Widget child) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      sliver: SliverToBoxAdapter(child: child),
    );
  }

  Widget _buildNoMatchingSourcesCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _panelDecoration(radius: 20),
      child: Row(
        children: [
          const Icon(Icons.filter_alt_off_outlined),
          const SizedBox(width: 12),
          Expanded(child: Text(context.l10n.bookSourcesNoMatchingSources)),
          TextButton(
            onPressed: () {
              _searchController.clear();
              _updateSourceView(() {
                _searchQuery = '';
                _filter = _BookSourceFilter.all;
                _selectedGroup = null;
              });
            },
            child: Text(context.l10n.bookSourcesResetFilters),
          ),
        ],
      ),
    );
  }

  Widget _buildBulkActions(bool additionalProtocolsEnabled) {
    final allIds = _visibleSources.map((source) => source.id).toSet();
    final allSelected =
        allIds.isNotEmpty && _selectedSourceIds.containsAll(allIds);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => setState(() {
            if (allSelected) {
              _selectedSourceIds.clear();
            } else {
              _selectedSourceIds
                ..clear()
                ..addAll(allIds);
            }
          }),
          icon: Icon(
            allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          ),
          label: Text(
            allSelected
                ? context.l10n.bookSourcesClearSelection
                : context.l10n.bookSourcesSelectAll,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: _selectedSourceIds.isEmpty
              ? null
              : () => _setSelectedSourcesEnabled(
                  true,
                  additionalProtocolsEnabled,
                ),
          icon: const Icon(Icons.toggle_on_outlined),
          label: Text(context.l10n.bookSourcesEnableSelected),
        ),
        OutlinedButton.icon(
          onPressed: _selectedSourceIds.isEmpty
              ? null
              : () => _setSelectedSourcesEnabled(
                  false,
                  additionalProtocolsEnabled,
                ),
          icon: const Icon(Icons.toggle_off_outlined),
          label: Text(context.l10n.bookSourcesDisableSelected),
        ),
        TextButton.icon(
          onPressed: _selectedSourceIds.isEmpty ? null : _removeSelectedSources,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(context.l10n.bookSourcesDeleteSelected),
        ),
      ],
    );
  }

  void _toggleSourceSelection(RegisteredBookSource source) {
    setState(() {
      if (!_selectedSourceIds.add(source.id)) {
        _selectedSourceIds.remove(source.id);
      }
    });
  }

  Future<void> _setSelectedSourcesEnabled(
    bool enabled,
    bool additionalProtocolsEnabled,
  ) async {
    final allowedIds = _sources
        .where(
          (source) =>
              _selectedSourceIds.contains(source.id) &&
              (!enabled ||
                  source.sourceProtocol == BookSourceProtocolKind.orsp ||
                  additionalProtocolsEnabled),
        )
        .map((source) => source.id);
    final sources = await _registry.setEnabledAll(allowedIds, enabled);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _removeSelectedSources() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesDeleteSelected),
        content: Text(
          context.l10n.bookSourcesDeleteSelectedMessage(
            _selectedSourceIds.length,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.bookSourcesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.bookSourcesConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final sources = await _registry.removeAll(_selectedSourceIds);
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _selectedSourceIds.clear();
      _selectionMode = false;
    });
  }

  List<Widget> _buildSourceGroupSlivers({
    required String title,
    required List<RegisteredBookSource> sources,
    required int totalCount,
    required bool additionalProtocolsEnabled,
  }) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$totalCount',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            return _buildSourceCard(
              sources[index],
              additionalProtocolsEnabled: additionalProtocolsEnabled,
            );
          }, childCount: sources.length),
        ),
      ),
    ];
  }

  Widget _buildSourceCard(
    RegisteredBookSource source, {
    required bool additionalProtocolsEnabled,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final canEnable =
        source.capabilities.isNotEmpty &&
        (source.sourceProtocol == BookSourceProtocolKind.orsp ||
            additionalProtocolsEnabled);
    final selected = _selectedSourceIds.contains(source.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          return Container(
            key: ValueKey('bookSourceCard-${source.id}'),
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 18,
              compact ? 16 : 14,
              compact ? 10 : 8,
              compact ? 12 : 14,
            ),
            decoration: _panelDecoration(radius: 20),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectionMode)
                            Checkbox(
                              value: selected,
                              onChanged: (_) => _toggleSourceSelection(source),
                            )
                          else
                            _buildSourceIcon(source, size: 52),
                          const SizedBox(width: 13),
                          Expanded(child: _buildSourceSummary(source)),
                          _buildSourceMenu(source),
                        ],
                      ),
                      if (source.capabilities.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _buildCapabilityChips(source),
                      ],
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.only(left: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainer.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source.enabled
                                    ? context.l10n.bookSourcesEnabled
                                    : context.l10n.bookSourcesDisabled,
                                style: TextStyle(
                                  color: source.enabled
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Switch.adaptive(
                              value: source.enabled,
                              onChanged: !canEnable
                                  ? null
                                  : (enabled) =>
                                        _setSourceEnabled(source, enabled),
                            ),
                            if (source.sourceProtocol ==
                                BookSourceProtocolKind.orsp)
                              IconButton(
                                tooltip: context.l10n.bookSourcesRefresh,
                                onPressed: () => _refreshSource(source),
                                icon: const Icon(Icons.refresh_rounded),
                              ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      if (_selectionMode)
                        Checkbox(
                          value: selected,
                          onChanged: (_) => _toggleSourceSelection(source),
                        )
                      else
                        _buildSourceIcon(source),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSourceSummary(source),
                            if (source.capabilities.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              _buildCapabilityChips(source),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        source.enabled
                            ? context.l10n.bookSourcesEnabled
                            : context.l10n.bookSourcesDisabled,
                        style: TextStyle(
                          color: source.enabled
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!_selectionMode)
                        Switch.adaptive(
                          value: source.enabled,
                          onChanged: !canEnable
                              ? null
                              : (enabled) => _setSourceEnabled(source, enabled),
                        ),
                      if (!_selectionMode &&
                          source.sourceProtocol == BookSourceProtocolKind.orsp)
                        IconButton(
                          tooltip: context.l10n.bookSourcesRefresh,
                          onPressed: () => _refreshSource(source),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      if (!_selectionMode) _buildSourceMenu(source),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildSourceSummary(RegisteredBookSource source) {
    final scheme = Theme.of(context).colorScheme;
    final groups = _sourceGroups(source);
    final runnable = source.capabilities.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          source.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          source.description.isEmpty
              ? source.apiBaseUrl.host
              : source.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource ||
            groups.isNotEmpty) ...[
          const SizedBox(height: 7),
          Wrap(
            spacing: 7,
            runSpacing: 5,
            children: [
              if (source.sourceProtocol == BookSourceProtocolKind.readingSource)
                _buildSourceMetaPill(
                  runnable
                      ? context.l10n.bookSourcesRunnable
                      : context.l10n.bookSourcesPendingCompatibility,
                  runnable ? Icons.check_circle_outline : Icons.extension_off,
                  runnable ? scheme.primary : scheme.onSurfaceVariant,
                ),
              for (final group in groups.take(2))
                _buildSourceMetaPill(
                  group,
                  Icons.folder_outlined,
                  scheme.onSurfaceVariant,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSourceMetaPill(String label, IconData icon, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildCapabilityChips(RegisteredBookSource source) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = source.capabilities.toList()..sort();
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: capabilities
          .map(
            (capability) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                capability,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSourceMenu(RegisteredBookSource source) {
    return PopupMenuButton<String>(
      tooltip: context.l10n.bookSourcesRemove,
      onSelected: (value) {
        if (value == 'rights') _showSourceRightsDialog(source);
        if (value == 'login') {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SourceLoginPage(source: source),
            ),
          );
        }
        if (value == 'remove') _confirmRemoveSource(source);
      },
      itemBuilder: (context) => [
        if (source.sourceProtocol == BookSourceProtocolKind.orsp)
          PopupMenuItem(
            value: 'rights',
            child: Text(context.l10n.bookSourcesRightsDetails),
          ),
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource &&
            '${source.sourceConfig?['loginUrl'] ?? ''}'.trim().isNotEmpty)
          PopupMenuItem(
            value: 'login',
            child: Row(
              children: [
                const Icon(Icons.key_rounded),
                const SizedBox(width: 10),
                Text(context.l10n.sourceLoginTitle),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              const Icon(Icons.delete_outline_rounded),
              const SizedBox(width: 10),
              Text(context.l10n.bookSourcesRemove),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSourceIcon(RegisteredBookSource source, {double size = 48}) {
    final scheme = Theme.of(context).colorScheme;
    final initial = source.name.characters.firstOrNull?.toUpperCase() ?? '?';
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    if (source.iconUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.29),
      child: SourceCoverImage(
        url: source.iconUrl!,
        fallback: fallback,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildProtocolCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _panelDecoration(radius: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.api_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.bookSourcesProtocolTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.bookSourcesProtocolDescription,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _showProtocolDialog,
                      icon: const Icon(Icons.schema_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesProtocolDetails),
                    ),
                    TextButton.icon(
                      onPressed: _openProtocolRepository,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text(context.l10n.bookSourcesProtocolRepository),
                    ),
                    TextButton.icon(
                      onPressed: _openRightsReport,
                      icon: const Icon(Icons.report_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesRightsReport),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _panelDecoration({required double radius}) {
    final palette = PageStyleHelper.palette(context);
    return BoxDecoration(
      color: palette.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: palette.border),
    );
  }

  Future<void> _setSourceEnabled(
    RegisteredBookSource source,
    bool enabled,
  ) async {
    final sources = await _registry.setEnabled(source.id, enabled);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _refreshSource(RegisteredBookSource source) async {
    try {
      final sources = await _registry.refresh(source, _sourceClient);
      if (!mounted) return;
      setState(() => _sources = sources);
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshed,
        kind: SideToastKind.success,
      );
    } on BookSourceProtocolException {
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshFailed,
        kind: SideToastKind.error,
      );
    } catch (_) {
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _confirmRemoveSource(RegisteredBookSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesRemoveTitle),
        content: Text(context.l10n.bookSourcesRemoveMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.bookSourcesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.bookSourcesConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final sources = await _registry.remove(source.id);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _showSourceRightsDialog(RegisteredBookSource source) async {
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.bookSourcesRightsDetails),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _rightsField(
                  context.l10n.bookSourcesOperator,
                  source.operatorName,
                ),
                _rightsField(
                  context.l10n.bookSourcesContentLicense,
                  source.contentLicense,
                ),
                _rightsField(
                  context.l10n.bookSourcesRightsStatement,
                  source.rightsStatement,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.bookSourcesRightsUnverifiedNotice,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (source.contactUrl != null)
                      TextButton.icon(
                        onPressed: () => _openExternalUrl(source.contactUrl!),
                        icon: const Icon(
                          Icons.contact_support_outlined,
                          size: 18,
                        ),
                        label: Text(context.l10n.bookSourcesContactOperator),
                      ),
                    TextButton.icon(
                      onPressed: _openRightsReport,
                      icon: const Icon(Icons.report_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesRightsReport),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.bookSourcesClose),
          ),
        ],
      ),
    );
  }

  Widget _rightsField(String label, String value) {
    final displayed = value.trim().isEmpty
        ? context.l10n.bookSourcesRightsNotProvided
        : value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          SelectableText(displayed, style: const TextStyle(height: 1.4)),
        ],
      ),
    );
  }

  Future<void> _showAddSourceDialog() async {
    final controller = TextEditingController();
    var connecting = false;
    var responsibilityAccepted = false;
    var mode = _AddSourceMode.link;
    BookSourceImportAnalysis? analysis;
    String? errorText;

    Future<void> analyzeLink(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      setRouteState(() {
        connecting = true;
        errorText = null;
      });
      try {
        final result = await _sourceImportAnalyzer.analyzeUrl(controller.text);
        if (!routeContext.mounted) return;
        setRouteState(() {
          analysis = result;
          connecting = false;
        });
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Future<void> chooseFile(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > SourceImportService.maxImportBytes) {
        setRouteState(() => errorText = 'Source file exceeds 64 MiB.');
        return;
      }
      final bytes = file.bytes;
      if (bytes == null) {
        setRouteState(() => errorText = 'Could not read source file.');
        return;
      }
      setRouteState(() {
        connecting = true;
        errorText = null;
        analysis = null;
      });
      try {
        final detected = await _sourceImportAnalyzer.analyzeBytesAsync(bytes);
        if (!routeContext.mounted) return;
        setRouteState(() {
          analysis = detected;
          connecting = false;
        });
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Future<void> addDetected(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final detected = analysis;
      if (detected == null) return;
      if (detected.kind == BookSourceImportKind.additional &&
          !_additionalProtocolsEnabled()) {
        setRouteState(() {
          errorText = context.l10n.bookSourcesAdvancedFeatureRequired;
        });
        return;
      }
      setRouteState(() {
        connecting = true;
        errorText = null;
      });
      try {
        late final List<RegisteredBookSource> sources;
        var importedAdditionalCount = 0;
        if (detected.kind == BookSourceImportKind.orsp) {
          sources = await _registry.upsert(detected.sources.single);
        } else {
          final preview = detected.additionalPreview!;
          importedAdditionalCount = preview.sources.length;
          sources = await _registry.upsertAll(preview.toRegisteredSources());
        }
        if (!mounted || !routeContext.mounted) return;
        Navigator.pop(routeContext);
        setState(() => _sources = sources);
        showSideToast(
          context,
          detected.kind == BookSourceImportKind.orsp
              ? '${context.l10n.bookSourcesAdded}: ${detected.sources.single.name}'
              : context.l10n.additionalSourcesImported(importedAdditionalCount),
          kind: SideToastKind.success,
        );
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Widget buildPanel(
      BuildContext routeContext,
      StateSetter setRouteState, {
      required bool sheet,
    }) {
      return _AddBookSourcePanel(
        controller: controller,
        connecting: connecting,
        responsibilityAccepted: responsibilityAccepted,
        mode: mode,
        analysis: analysis,
        errorText: errorText,
        sheet: sheet,
        onModeChanged: (value) => setRouteState(() {
          mode = value;
          analysis = null;
          errorText = null;
        }),
        onResponsibilityChanged: (value) =>
            setRouteState(() => responsibilityAccepted = value),
        onCancel: () => Navigator.pop(routeContext),
        onAnalyzeLink: () => analyzeLink(routeContext, setRouteState),
        onChooseFile: () => chooseFile(routeContext, setRouteState),
        onAdd: () => addDetected(routeContext, setRouteState),
      );
    }

    if (LayoutHelper.isMobile(context)) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: buildPanel(sheetContext, setSheetState, sheet: true),
            ),
          ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        barrierDismissible: !connecting,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
              child: buildPanel(dialogContext, setDialogState, sheet: false),
            ),
          ),
        ),
      );
    }
    controller.dispose();
  }

  bool _additionalProtocolsEnabled() {
    try {
      return context
          .read<AppSettingsNotifier>()
          .additionalSourceProtocolsEnabled;
    } on ProviderNotFoundException {
      return false;
    }
  }

  void _showProtocolDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesProtocolDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.bookSourcesProtocolDialogBody,
                style: const TextStyle(height: 1.5),
              ),
              const SizedBox(height: 18),
              SelectableText(
                openReadingSourceProtocolRepositoryUrl,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openProtocolRepository,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(context.l10n.bookSourcesProtocolRepositoryOpen),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesClose),
          ),
        ],
      ),
    );
  }

  Future<void> _openProtocolRepository() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingSourceProtocolRepositoryUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesProtocolRepositoryOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openRightsReport() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingRightsReportUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesRightsReportOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<bool> _openExternalUrl(Uri url) {
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }
}

enum _BookSourceFilter { all, enabled, disabled, runnable, pending }

enum _BookSourceHeaderAction { add, select }

class _BookSourceGroupPicker extends StatefulWidget {
  const _BookSourceGroupPicker({required this.groups, required this.selected});

  final List<String> groups;
  final String? selected;

  @override
  State<_BookSourceGroupPicker> createState() => _BookSourceGroupPickerState();
}

class _BookSourceGroupPickerState extends State<_BookSourceGroupPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final groups = widget.groups
        .where((group) => query.isEmpty || group.toLowerCase().contains(query))
        .toList(growable: false);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              context.l10n.bookSourcesChooseGroup,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('bookSourceGroupSearchField'),
              decoration: InputDecoration(
                hintText: context.l10n.bookSourcesSearchGroups,
                prefixIcon: const Icon(Icons.search_rounded),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: groups.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    leading: Icon(
                      widget.selected == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(context.l10n.bookSourcesAllGroups),
                    onTap: () => Navigator.pop(context, ''),
                  );
                }
                final group = groups[index - 1];
                return ListTile(
                  leading: Icon(
                    widget.selected == group
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(group),
                  onTap: () => Navigator.pop(context, group),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _AddSourceMode { link, file }

class _AddBookSourcePanel extends StatelessWidget {
  final TextEditingController controller;
  final bool connecting;
  final bool responsibilityAccepted;
  final _AddSourceMode mode;
  final BookSourceImportAnalysis? analysis;
  final String? errorText;
  final bool sheet;
  final ValueChanged<_AddSourceMode> onModeChanged;
  final ValueChanged<bool> onResponsibilityChanged;
  final VoidCallback onCancel;
  final VoidCallback onAnalyzeLink;
  final VoidCallback onChooseFile;
  final VoidCallback onAdd;

  const _AddBookSourcePanel({
    required this.controller,
    required this.connecting,
    required this.responsibilityAccepted,
    required this.mode,
    required this.analysis,
    required this.errorText,
    required this.sheet,
    required this.onModeChanged,
    required this.onResponsibilityChanged,
    required this.onCancel,
    required this.onAnalyzeLink,
    required this.onChooseFile,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, sheet ? 4 : 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.bookSourcesAdd,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_AddSourceMode>(
              key: const Key('bookSourceAddMode'),
              segments: [
                ButtonSegment(
                  value: _AddSourceMode.link,
                  icon: const Icon(Icons.link_rounded),
                  label: Text(context.l10n.bookSourcesImportLink),
                ),
                ButtonSegment(
                  value: _AddSourceMode.file,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(context.l10n.additionalSourcesChooseFile),
                ),
              ],
              selected: {mode},
              onSelectionChanged: connecting
                  ? null
                  : (selection) => onModeChanged(selection.first),
            ),
            const SizedBox(height: 20),
            if (mode == _AddSourceMode.link) ...[
              TextField(
                key: const Key('bookSourceUnifiedUrlField'),
                controller: controller,
                enabled: !connecting,
                autofocus: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.l10n.bookSourcesUrlLabel,
                  hintText: context.l10n.bookSourcesUrlHint,
                  prefixIcon: const Icon(Icons.link_rounded),
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else
              OutlinedButton.icon(
                key: const Key('bookSourceChooseJsonButton'),
                onPressed: connecting ? null : onChooseFile,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(context.l10n.additionalSourcesChooseFile),
              ),
            if (analysis case final detected?) ...[
              const SizedBox(height: 14),
              _DetectedSourceSummary(analysis: detected),
            ],
            if (errorText != null) ...[
              const SizedBox(height: 10),
              Text(errorText!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, size: 21, color: scheme.primary),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      context.l10n.bookSourcesNoOfficialSourcesNotice,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('bookSourceResponsibilityCheckbox'),
              value: responsibilityAccepted,
              enabled: !connecting,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                context.l10n.bookSourcesResponsibilityAck,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              onChanged: connecting
                  ? null
                  : (value) => onResponsibilityChanged(value ?? false),
            ),
            if (connecting) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(context.l10n.bookSourcesConnecting),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: connecting ? null : onCancel,
                    child: Text(context.l10n.bookSourcesCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('bookSourceConnectButton'),
                    onPressed: connecting || !responsibilityAccepted
                        ? null
                        : analysis == null
                        ? mode == _AddSourceMode.link
                              ? onAnalyzeLink
                              : null
                        : onAdd,
                    child: Text(
                      analysis == null
                          ? context.l10n.bookSourcesAnalyze
                          : context.l10n.bookSourcesConfirm,
                    ),
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

class _DetectedSourceSummary extends StatelessWidget {
  const _DetectedSourceSummary({required this.analysis});

  final BookSourceImportAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = analysis.additionalPreview;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            analysis.kind == BookSourceImportKind.orsp
                ? context.l10n.bookSourcesDetectedOrsp
                : context.l10n.bookSourcesDetectedAdditional,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          if (analysis.kind == BookSourceImportKind.orsp)
            Text(analysis.sources.single.name)
          else if (preview != null)
            Text(
              context.l10n.additionalSourcesQuickPreview(
                preview.sources.length,
                preview.skipped,
              ),
            ),
        ],
      ),
    );
  }
}
