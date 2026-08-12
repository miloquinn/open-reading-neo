import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_import_analyzer.dart';
import '../../book_sources/source_engine/source_health_checker.dart';
import '../../book_sources/source_engine/source_import_service.dart';
import '../../services/core/app_settings_service.dart';
import '../../utils/layout_helper.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../../widgets/side_toast.dart';
import 'controllers/book_source_add_controller.dart';
import 'controllers/book_source_management_controller.dart';
import 'source_debug_page.dart';
import 'source_login_page.dart';
import 'widgets/book_source_add_panel.dart';
import 'widgets/book_source_cleanup_review_sheet.dart';
import 'widgets/book_source_group_picker.dart';
import 'widgets/book_source_management_list.dart';
import 'widgets/book_source_management_source_card.dart';

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
  static const double _loadMoreExtent = 800;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final BookSourceManagementController _controller;

  // `visibleSources`/`availableGroups` re-filter every source and regex-parse
  // each one's group tags; this page rebuilds on every controller
  // notification (a single health-check progress tick among thousands
  // included), so recomputing them unconditionally on every build is what
  // made this page feel like it never finished loading with a large library.
  int? _cachedVisibleSourcesRevision;
  String? _cachedVisibleSourcesQuery;
  BookSourceManagementFilter? _cachedVisibleSourcesFilter;
  String? _cachedVisibleSourcesGroup;
  List<RegisteredBookSource>? _cachedVisibleSources;
  int? _cachedAvailableGroupsRevision;
  List<String>? _cachedAvailableGroups;

  List<RegisteredBookSource> _memoizedVisibleSources() {
    final state = _controller.state;
    if (_cachedVisibleSourcesRevision == state.sourcesRevision &&
        _cachedVisibleSourcesQuery == state.query &&
        _cachedVisibleSourcesFilter == state.filter &&
        _cachedVisibleSourcesGroup == state.selectedGroup) {
      return _cachedVisibleSources!;
    }
    final visible = state.visibleSources;
    _cachedVisibleSourcesRevision = state.sourcesRevision;
    _cachedVisibleSourcesQuery = state.query;
    _cachedVisibleSourcesFilter = state.filter;
    _cachedVisibleSourcesGroup = state.selectedGroup;
    _cachedVisibleSources = visible;
    return visible;
  }

  List<String> _memoizedAvailableGroups() {
    final state = _controller.state;
    if (_cachedAvailableGroupsRevision == state.sourcesRevision) {
      return _cachedAvailableGroups!;
    }
    final groups = state.availableGroups;
    _cachedAvailableGroupsRevision = state.sourcesRevision;
    _cachedAvailableGroups = groups;
    return groups;
  }

  @override
  void initState() {
    super.initState();
    _controller = BookSourceManagementController()..addListener(_onChanged);
    _scrollController.addListener(_loadMoreSourcesIfNeeded);
    unawaited(_controller.load());
  }

  void _onChanged() {
    if (mounted) setState(() {});
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
              value: _BookSourceHeaderAction.cleanup,
              itemKey: const Key('bookSourcesCleanupButton'),
              child: ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: Text(context.l10n.bookSourcesCleanupMenuLabel),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.protocolDetails,
              itemKey: const Key('bookSourcesProtocolButton'),
              child: ListTile(
                leading: const Icon(Icons.api_rounded),
                title: Text(context.l10n.bookSourcesProtocolTitle),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.protocolRepository,
              child: ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: Text(context.l10n.bookSourcesProtocolRepository),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _BookSourceHeaderAction.rightsReport,
              child: ListTile(
                leading: const Icon(Icons.report_outlined),
                title: Text(context.l10n.bookSourcesRightsReport),
              ),
            ),
          ],
          onSelected: (action) {
            switch (action) {
              case _BookSourceHeaderAction.add:
                unawaited(_showAddSourceDialog());
              case _BookSourceHeaderAction.select:
                _controller.toggleSelectionMode();
              case _BookSourceHeaderAction.cleanup:
                unawaited(_runCleanupSweep());
              case _BookSourceHeaderAction.protocolDetails:
                _showProtocolDialog();
              case _BookSourceHeaderAction.protocolRepository:
                unawaited(_openProtocolRepository());
              case _BookSourceHeaderAction.rightsReport:
                unawaited(_openRightsReport());
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
            visibleSources: _memoizedVisibleSources(),
            availableGroups: _memoizedAvailableGroups(),
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
        groups: _memoizedAvailableGroups(),
        selected: state.selectedGroup,
      ),
    );
    if (!mounted || selected == null) return;
    final normalized = selected.isEmpty ? null : selected;
    if (normalized == _controller.state.selectedGroup) return;
    _controller.setGroup(normalized);
    _resetScroll();
  }

  void _handleSourceAction(
    RegisteredBookSource source,
    BookSourceManagementSourceAction action,
  ) {
    switch (action) {
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

  Future<void> _runCleanupSweep() async {
    // Closing the dialog by any means — the Cancel button, tapping the
    // barrier, or the system back gesture — counts as a cancel request: a
    // library can run into the thousands of sources, so this must never be
    // a dead end the user can't back out of.
    var sweepFinished = false;
    var cancelledByUser = false;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    final progress = _controller.state.healthProgress;
                    return Text(
                      progress == null
                          ? context.l10n.bookSourcesCleanupMenuLabel
                          : '${progress.completed}/${progress.total}',
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.bookSourcesCancel),
            ),
          ],
        ),
      ).whenComplete(() {
        if (!sweepFinished) {
          cancelledByUser = true;
          _controller.cancelCleanupSweep();
        }
      }),
    );

    final BookSourceCleanupSweepResult result;
    try {
      result = await _controller.runCleanupSweep();
    } on Object catch (error) {
      sweepFinished = true;
      if (!cancelledByUser && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) showSideToast(context, '$error', kind: SideToastKind.error);
      return;
    }
    sweepFinished = true;
    if (!cancelledByUser && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    final total = result.fullyAvailable.length + result.needsAttention.length;
    if (cancelledByUser) {
      showSideToast(
        context,
        context.l10n.bookSourcesCleanupCancelledSummary(total),
        kind: SideToastKind.info,
      );
      return;
    }
    if (total == 0) {
      showSideToast(
        context,
        context.l10n.bookSourcesCleanupNoCheckableSources,
        kind: SideToastKind.info,
      );
      return;
    }
    if (result.needsAttention.isEmpty) {
      showSideToast(
        context,
        context.l10n.bookSourcesCleanupAllFullyAvailable(
          result.fullyAvailable.length,
        ),
        kind: SideToastKind.success,
      );
      return;
    }
    final toDisable = await showModalBottomSheet<Set<String>>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => BookSourceCleanupReviewSheet(
        fullyAvailableCount: result.fullyAvailable.length,
        needsAttention: result.needsAttention,
      ),
    );
    if (toDisable == null || toDisable.isEmpty || !mounted) return;
    await _controller.disableSources(toDisable);
    if (!mounted) return;
    showSideToast(
      context,
      context.l10n.bookSourcesCleanupDisabledSummary(toDisable.length),
      kind: SideToastKind.success,
    );
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

  Future<void> _showAddSourceDialog() async {
    final textController = TextEditingController();
    final addController = BookSourceAddController();
    var responsibilityAccepted = false;
    var mode = BookSourceAddMode.link;

    Future<void> chooseFile(StateSetter setRouteState) async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > SourceImportService.maxImportBytes) {
        setRouteState(() {});
        _showAddFileError(addController, 'Source file exceeds 64 MiB.');
        return;
      }
      final bytes = file.bytes;
      if (bytes == null) {
        _showAddFileError(addController, 'Could not read source file.');
        setRouteState(() {});
        return;
      }
      final pending = addController.analyzeBytes(bytes);
      setRouteState(() {});
      await pending;
      setRouteState(() {});
    }

    Future<void> analyzeLink(StateSetter setRouteState) async {
      final pending = addController.analyzeUrl(textController.text);
      setRouteState(() {});
      await pending;
      setRouteState(() {});
    }

    Future<void> addDetected(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final detected = addController.state.analysis;
      if (detected == null) return;
      if (detected.kind == BookSourceImportKind.additional &&
          !_additionalProtocolsEnabled()) {
        _showAddFileError(
          addController,
          context.l10n.bookSourcesAdvancedFeatureRequired,
        );
        setRouteState(() {});
        return;
      }
      final pending = addController.commit();
      setRouteState(() {});
      final result = await pending;
      if (!mounted || !routeContext.mounted) return;
      setRouteState(() {});
      if (result == null) return;
      Navigator.pop(routeContext);
      _controller.replaceSources(result.sources);
      showSideToast(context, switch (result.analysis.kind) {
        BookSourceImportKind.orsp =>
          '${context.l10n.bookSourcesAdded}: ${result.analysis.sources.single.name}',
        BookSourceImportKind.additional when result.conflictedCount > 0 =>
          context.l10n.additionalSourcesImportedWithConflicts(
            result.importedCount,
            result.conflictedCount,
          ),
        BookSourceImportKind.additional =>
          context.l10n.additionalSourcesImported(result.importedCount),
      }, kind: SideToastKind.success);
    }

    Widget buildPanel(
      BuildContext routeContext,
      StateSetter setRouteState, {
      required bool sheet,
    }) {
      final addState = addController.state;
      return BookSourceAddPanel(
        controller: textController,
        connecting: addState.loading,
        responsibilityAccepted: responsibilityAccepted,
        mode: mode,
        analysis: addState.analysis,
        errorText: addState.error?.toString(),
        sheet: sheet,
        onModeChanged: (value) => setRouteState(() {
          mode = value;
          addController.clear();
        }),
        onResponsibilityChanged: (value) =>
            setRouteState(() => responsibilityAccepted = value),
        onCancel: () => Navigator.pop(routeContext),
        onAnalyzeLink: () => unawaited(analyzeLink(setRouteState)),
        onChooseFile: () => unawaited(chooseFile(setRouteState)),
        onAdd: () => unawaited(addDetected(routeContext, setRouteState)),
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
        barrierDismissible: !addController.state.loading,
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
    textController.dispose();
    addController.dispose();
  }

  void _showAddFileError(BookSourceAddController controller, Object error) {
    controller.setError(error);
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

enum _BookSourceHeaderAction {
  add,
  select,
  cleanup,
  protocolDetails,
  protocolRepository,
  rightsReport,
}
