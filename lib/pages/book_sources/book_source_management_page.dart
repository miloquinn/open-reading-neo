import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_import_analyzer.dart';
import '../../book_sources/services/book_source_registry.dart';
import '../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../book_sources/services/book_source_usage_service.dart';
import '../../book_sources/source_engine/source_health_checker.dart';
import '../../services/core/app_settings_service.dart';
import '../../utils/layout_helper.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../../widgets/side_toast.dart';
import 'controllers/book_source_add_controller.dart';
import 'controllers/book_source_management_controller.dart';
import 'source_debug_page.dart';
import 'source_login_page.dart';
import 'widgets/book_source_add_flow.dart';
import 'widgets/book_source_cleanup_review_sheet.dart';
import 'widgets/book_source_dedupe_review_sheet.dart';
import 'widgets/book_source_group_picker.dart';
import 'widgets/book_source_organization_actions.dart';
import 'widgets/book_source_information_sheet.dart';
import 'widgets/book_source_management_list.dart';
import 'widgets/book_source_management_source_card.dart';
import 'widgets/book_source_maintenance_sheet.dart';

part 'book_source_management_add_source.dart';
part 'book_source_management_maintenance.dart';

/// Low-frequency configuration for online content providers.
///
/// Discovery remains user-facing; adding, enabling and removing providers lives
/// here so technical configuration does not interrupt the book-browsing flow.
class BookSourceManagementPage extends StatefulWidget {
  const BookSourceManagementPage({
    super.key,
    this.maintenance,
    this.registry,
    this.readReferencedSourceIds = referencedBookSourceIds,
  });

  final BookSourceMaintenanceCoordinator? maintenance;
  final BookSourceRegistry? registry;
  final Future<Set<String>> Function() readReferencedSourceIds;

  @override
  State<BookSourceManagementPage> createState() =>
      _BookSourceManagementPageState();
}

class _BookSourceManagementPageState extends State<BookSourceManagementPage> {
  static const double _loadMoreExtent = 800;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final BookSourceManagementController _controller;
  late final BookSourceMaintenanceCoordinator _maintenance;
  late final bool _ownsMaintenance;
  int _handledMaintenanceRunId = 0;
  bool _maintenanceProgressOpen = false;
  bool _dedupeRunning = false;
  BookSourceMaintenanceStatus? _lastMaintenanceStatus;

  @override
  void initState() {
    super.initState();
    final injected = widget.maintenance;
    if (injected != null) {
      _maintenance = injected;
      _ownsMaintenance = false;
    } else {
      try {
        _maintenance = context.read<BookSourceMaintenanceCoordinator>();
        _ownsMaintenance = false;
      } on ProviderNotFoundException {
        _maintenance = BookSourceMaintenanceCoordinator();
        _ownsMaintenance = true;
      }
    }
    _handledMaintenanceRunId = _maintenance.state.isRunning
        ? _maintenance.state.runId - 1
        : _maintenance.state.runId;
    _lastMaintenanceStatus = _maintenance.state.status;
    _maintenance.addListener(_onMaintenanceChanged);
    _controller = BookSourceManagementController(registry: widget.registry)
      ..addListener(_onChanged);
    _scrollController.addListener(_loadMoreSourcesIfNeeded);
    unawaited(_controller.load());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onMaintenanceChanged() {
    if (!mounted) return;
    final state = _maintenance.state;
    final statusChanged = state.status != _lastMaintenanceStatus;
    _lastMaintenanceStatus = state.status;
    if (!state.isRunning && state.runId > _handledMaintenanceRunId) {
      _handledMaintenanceRunId = state.runId;
      final result = state.result;
      if (result != null) {
        final remainingIds = state.remainingSources
            .map((source) => source.id)
            .toSet();
        _controller.mergeExternalHealthResults([
          for (final source in result.allSources)
            if (!remainingIds.contains(source.id)) source,
        ]);
      }
      if (!_maintenanceProgressOpen && state.failure != null) {
        showSideToast(context, '${state.failure}', kind: SideToastKind.error);
      } else if (!_maintenanceProgressOpen && result != null) {
        showSideToast(
          context,
          state.status == BookSourceMaintenanceStatus.cancelled
              ? context.l10n.bookSourcesCleanupCancelledSummary(
                  state.progress?.completed ?? result.total,
                )
              : context.l10n.bookSourcesMaintenanceFinishedSummary(
                  state.progress?.completed ?? result.total,
                  result.needsAttention.length,
                ),
          kind: state.status == BookSourceMaintenanceStatus.cancelled
              ? SideToastKind.info
              : result.needsAttention.isEmpty
              ? SideToastKind.success
              : SideToastKind.warning,
        );
      }
    }
    if (statusChanged) setState(() {});
  }

  void _loadMoreSourcesIfNeeded() {
    if (_controller.state.loading || !_scrollController.hasClients) return;
    if (!_scrollController.position.isScrollingNotifier.value) return;
    if (_scrollController.position.extentAfter > _loadMoreExtent) return;
    _controller.loadMore();
  }

  void _resetScroll() {
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
    _maintenance.removeListener(_onMaintenanceChanged);
    if (_ownsMaintenance) _maintenance.dispose();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var additionalProtocolsEnabled = false;
    try {
      additionalProtocolsEnabled = context
          .watch<AppSettingsNotifier>()
          .additionalSourceProtocolsEnabled;
    } on ProviderNotFoundException {
      // Standalone embeds without app settings retain the default-off state.
    }
    _controller.setAdditionalProtocolsEnabled(additionalProtocolsEnabled);
    final state = _controller.state;
    return FloatingSubpageScaffold(
      title: context.l10n.bookSourceManagementTitle,
      actions: [
        FloatingSubpageMenuButton<_BookSourceHeaderAction>(
          key: const Key('bookSourcesToolButton'),
          tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
          icon: Icons.more_horiz_rounded,
          items: [
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.add,
              itemKey: const Key('bookSourcesAddButton'),
              child: ListTile(
                leading: const Icon(Icons.add_link_rounded),
                title: Text(context.l10n.bookSourcesAdd),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.select,
              itemKey: const Key('bookSourcesSelectionModeButton'),
              child: ListTile(
                leading: Icon(
                  state.selectionMode
                      ? Icons.close_rounded
                      : Icons.checklist_rounded,
                ),
                title: Text(context.l10n.bookSourcesSelect),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.groups,
              itemKey: const Key('bookSourcesManageGroupsButton'),
              child: ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(
                  BookSourceOrganizationCopy.of(context).manageGroups,
                ),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.maintenance,
              itemKey: const Key('bookSourcesMaintenanceButton'),
              startsSection: true,
              iconColor: Theme.of(context).colorScheme.tertiary,
              child: AnimatedBuilder(
                animation: _maintenance,
                builder: (context, _) => ListTile(
                  leading: Icon(
                    _maintenance.state.isRunning
                        ? Icons.monitor_heart_rounded
                        : Icons.home_repair_service_outlined,
                  ),
                  title: Text(
                    _maintenance.state.isRunning
                        ? context.l10n.bookSourcesMaintenanceRunningMenuLabel(
                            _maintenance.state.progress?.completed ?? 0,
                            _maintenance.state.progress?.total ?? 0,
                          )
                        : context.l10n.bookSourcesMaintenanceTitle,
                  ),
                ),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.information,
              itemKey: const Key('bookSourcesProtocolButton'),
              startsSection: true,
              child: ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(context.l10n.bookSourcesInformationTitle),
              ),
            ),
          ],
          onSelected: (action) {
            switch (action) {
              case _BookSourceHeaderAction.add:
                unawaited(_showAddSourceDialog());
              case _BookSourceHeaderAction.select:
                _controller.toggleSelectionMode();
              case _BookSourceHeaderAction.groups:
                unawaited(_showGroupManager());
              case _BookSourceHeaderAction.maintenance:
                unawaited(_showMaintenanceMenu());
              case _BookSourceHeaderAction.information:
                unawaited(_showInformationMenu());
            }
          },
        ),
      ],
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: BookSourceManagementList(
            state: state,
            visibleSources: state.visibleSources,
            availableGroups: state.availableGroups,
            searchController: _searchController,
            scrollController: _scrollController,
            additionalProtocolsEnabled: additionalProtocolsEnabled,
            onQueryChanged: (query) {
              _controller.setQuery(query);
              _resetScroll();
            },
            onClearQuery: () {
              _searchController.clear();
              _controller.setQuery('');
              _resetScroll();
            },
            onFilterChanged: (filter) {
              _controller.setFilter(filter);
              _resetScroll();
            },
            onChooseGroup: _showGroupPicker,
            onResetFilters: () {
              _searchController.clear();
              _controller.resetFilters();
              _resetScroll();
            },
            onToggleSelectAll: _controller.toggleSelectAllVisible,
            onEnableSelected: () =>
                unawaited(_controller.setSelectedSourcesEnabled(true)),
            onDisableSelected: () =>
                unawaited(_controller.setSelectedSourcesEnabled(false)),
            onCheckSelected: () => unawaited(_checkSelectedSourcesHealth()),
            onGroupSelected: () => unawaited(
              _editSourceGroups([
                for (final source in state.sources)
                  if (state.selectedSourceIds.contains(source.id)) source,
              ]),
            ),
            onRemoveSelected: () => unawaited(_removeSelectedSources()),
            onToggleSourceSelection: (source) =>
                _controller.toggleSourceSelection(source.id),
            onSourceEnabledChanged: (source, enabled) =>
                unawaited(_controller.setSourceEnabled(source, enabled)),
            onSourceAction: _handleSourceAction,
          ),
        ),
      ),
    );
  }

  Future<void> _showGroupPicker() async {
    final state = _controller.state;
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => BookSourceGroupPicker(
        groups: state.availableGroups,
        selected: state.selectedGroup,
      ),
    );
    if (!mounted || selected == null) return;
    final normalized = selected.isEmpty ? null : selected;
    if (normalized == _controller.state.selectedGroup) return;
    _controller.setGroup(normalized);
    _resetScroll();
  }

  Future<void> _showGroupManager() async {
    await showBookSourceGroupManager(context, registry: _controller.registry);
    if (!mounted) return;
    await _reloadOrganization();
  }

  Future<void> _editSourceGroups(List<RegisteredBookSource> sources) async {
    final changed = await showBookSourceGroupEditor(
      context,
      registry: _controller.registry,
      sources: sources,
    );
    if (!mounted || !changed) return;
    await _reloadOrganization();
  }

  Future<void> _reloadOrganization() async {
    try {
      await _controller.reloadOrganization();
    } on Object catch (error) {
      if (mounted) showSideToast(context, '$error', kind: SideToastKind.error);
    }
  }

  Future<void> _toggleFavorite(RegisteredBookSource source) async {
    try {
      await _controller.setSourceFavorite(source);
    } on Object catch (error) {
      if (mounted) showSideToast(context, '$error', kind: SideToastKind.error);
    }
  }

  void _handleSourceAction(
    RegisteredBookSource source,
    BookSourceManagementSourceAction action,
  ) {
    switch (action) {
      case BookSourceManagementSourceAction.favorite:
        unawaited(_toggleFavorite(source));
      case BookSourceManagementSourceAction.groups:
        unawaited(_editSourceGroups([source]));
      case BookSourceManagementSourceAction.refresh:
        unawaited(_refreshSource(source));
      case BookSourceManagementSourceAction.rights:
        unawaited(_showSourceRightsDialog(source));
      case BookSourceManagementSourceAction.login:
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SourceLoginPage(source: source),
            ),
          ),
        );
      case BookSourceManagementSourceAction.debug:
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SourceDebugPage(source: source),
            ),
          ),
        );
      case BookSourceManagementSourceAction.health:
        unawaited(_checkSourceHealth(source));
      case BookSourceManagementSourceAction.remove:
        unawaited(_confirmRemoveSource(source));
    }
  }

  Future<void> _refreshSource(RegisteredBookSource source) async {
    final refreshed = await _controller.refreshSource(source);
    if (!mounted) return;
    showSideToast(
      context,
      refreshed
          ? context.l10n.bookSourcesRefreshed
          : context.l10n.bookSourcesRefreshFailed,
      kind: refreshed ? SideToastKind.success : SideToastKind.error,
    );
  }

  Future<void> _checkSelectedSourcesHealth() async {
    try {
      final updated = await _controller.checkSelectedSourcesHealth();
      if (!mounted || updated.isEmpty) return;
      final healthy = updated
          .where((source) => sourceHealthCheckResultOf(source)?.healthy == true)
          .length;
      showSideToast(
        context,
        context.l10n.bookSourcesHealthCheckSummary(healthy, updated.length),
        kind: healthy == updated.length
            ? SideToastKind.success
            : SideToastKind.error,
      );
    } on Object catch (error) {
      if (mounted) {
        showSideToast(context, '$error', kind: SideToastKind.error);
      }
    }
  }

  Future<void> _checkSourceHealth(RegisteredBookSource source) async {
    try {
      final updated = await _controller.checkSourceHealth(source);
      if (!mounted || updated == null) return;
      final result = sourceHealthCheckResultOf(updated);
      showSideToast(
        context,
        result?.healthy == true
            ? context.l10n.sourceHealthHealthy
            : _sourceHealthIssueSummary(result),
        kind: result?.healthy == true
            ? SideToastKind.success
            : SideToastKind.error,
      );
    } on Object catch (error) {
      if (mounted) {
        showSideToast(context, '$error', kind: SideToastKind.error);
      }
    }
  }

  Future<void> _showInformationMenu() async {
    final action = await showModalBottomSheet<BookSourceInformationAction>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const BookSourceInformationSheet(),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case BookSourceInformationAction.protocol:
        _showProtocolDialog();
      case BookSourceInformationAction.repository:
        await _openProtocolRepository();
      case BookSourceInformationAction.rightsReport:
        await _openRightsReport();
    }
  }

  String _sourceHealthIssueSummary(SourceHealthCheckResult? result) {
    if (result == null || result.timedOut) {
      return context.l10n.sourceHealthTimedOut;
    }
    final labels = result.failed
        .map((capability) => sourceHealthCapabilityLabel(context, capability))
        .join(', ');
    return context.l10n.sourceHealthFailedCapabilities(labels);
  }

  Future<void> _removeSelectedSources() async {
    final count = _controller.state.selectedSourceIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesDeleteSelected),
        content: Text(context.l10n.bookSourcesDeleteSelectedMessage(count)),
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
    if (confirmed == true) await _controller.removeSelectedSources();
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
    if (confirmed == true) await _controller.removeSource(source.id);
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
}

enum _BookSourceHeaderAction { add, select, groups, maintenance, information }
