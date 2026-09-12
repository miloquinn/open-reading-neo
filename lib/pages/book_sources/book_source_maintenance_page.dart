import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_health_configuration.dart';
import '../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../book_sources/source_engine/source_health_checker.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import 'controllers/book_source_management_controller.dart';
import 'widgets/book_source_management_source_card.dart';
import 'widgets/book_source_pill.dart';

enum _MaintenanceScope { enabled, all, selected }

/// A durable workspace for checking, filtering, and cleaning installed sources.
class BookSourceMaintenancePage extends StatefulWidget {
  const BookSourceMaintenancePage({
    super.key,
    required this.controller,
    required this.maintenance,
    required this.readReferencedSourceIds,
    required this.onDedupe,
  });

  final BookSourceManagementController controller;
  final BookSourceMaintenanceCoordinator maintenance;
  final Future<Set<String>> Function() readReferencedSourceIds;
  final Future<void> Function(Set<String>) onDedupe;

  @override
  State<BookSourceMaintenancePage> createState() =>
      _BookSourceMaintenancePageState();
}

class _BookSourceMaintenancePageState extends State<BookSourceMaintenancePage> {
  final _search = TextEditingController();
  final _filterScroll = ScrollController();
  bool _checkedOnly = false;
  BookSourceMaintenanceStatus? _lastStatus;
  final _selected = <String>{};
  Set<String> _referenced = const {};
  _MaintenanceScope _scope = _MaintenanceScope.enabled;
  BookSourceMaintenanceClassification? _classification;
  bool _problemsOnly = false;
  bool _busy = false;
  Object? _actionFailure;

  int? _cachedSourcesRevision;
  int? _cachedAssessmentSourcesRevision;
  int? _cachedRunId;
  Object? _cachedResult;
  BookSourceMaintenanceStatus? _cachedStatus;
  List<RegisteredBookSource> _cachedCheckableSources = const [];
  List<BookSourceMaintenanceAssessment> _cachedAssessments = const [];

  @override
  void initState() {
    super.initState();
    if (widget.controller.state.selectedSourceIds.isNotEmpty) {
      _scope = _MaintenanceScope.selected;
    }
    _lastStatus = widget.maintenance.state.status;
    _checkedOnly = _lastStatus == BookSourceMaintenanceStatus.cancelled;
    widget.controller.addListener(_changed);
    widget.maintenance.addListener(_changed);
    _search.addListener(_searchChanged);
    _loadReferences();
  }

  Future<void> _loadReferences() async {
    try {
      final ids = await widget.readReferencedSourceIds();
      if (mounted) setState(() => _referenced = ids);
    } on Object {
      // Reference information is advisory; cleanup remains available.
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.maintenance.removeListener(_changed);
    _search
      ..removeListener(_searchChanged)
      ..dispose();
    _filterScroll.dispose();
    super.dispose();
  }

  bool get _mutationBusy =>
      _busy ||
      widget.controller.state.loading ||
      widget.controller.state.mutation != null;

  void _searchChanged() {
    _selected.clear();
    _changed();
  }

  void _changed() {
    final status = widget.maintenance.state.status;
    if (status != _lastStatus &&
        status == BookSourceMaintenanceStatus.cancelled) {
      _checkedOnly = true;
      _classification = null;
      _problemsOnly = false;
      _selected.clear();
    }
    _lastStatus = status;
    if (mounted) setState(() {});
  }

  Set<String> get _currentCheckedIds {
    final result = widget.maintenance.state.result;
    if (result == null) return const {};
    final remaining = result.remainingSources
        .map((source) => source.id)
        .toSet();
    final current = {for (final source in _checkableSources) source.id: source};
    return {
      for (final item in result.assessments)
        if (!remaining.contains(item.source.id) &&
            current.containsKey(item.source.id) &&
            sameBookSourceHealthCheckConfiguration(
              current[item.source.id]!,
              item.source,
            ))
          item.source.id,
    };
  }

  List<RegisteredBookSource> get _checkableSources {
    final revision = widget.controller.state.sourcesRevision;
    if (_cachedSourcesRevision == revision) return _cachedCheckableSources;
    _cachedSourcesRevision = revision;
    return _cachedCheckableSources = widget.controller.state.sources
        .where(
          (source) =>
              source.sourceProtocol == BookSourceProtocolKind.readingSource,
        )
        .toList(growable: false);
  }

  Set<String> get _scopeIds {
    final state = widget.controller.state;
    return switch (_scope) {
      _MaintenanceScope.enabled =>
        _checkableSources
            .where((source) => source.enabled)
            .map((source) => source.id)
            .toSet(),
      _MaintenanceScope.all =>
        _checkableSources.map((source) => source.id).toSet(),
      _MaintenanceScope.selected =>
        _checkableSources
            .where((source) => state.selectedSourceIds.contains(source.id))
            .map((source) => source.id)
            .toSet(),
    };
  }

  List<BookSourceMaintenanceAssessment> get _assessments {
    final sourceRevision = widget.controller.state.sourcesRevision;
    final maintenanceState = widget.maintenance.state;
    final checkable = _checkableSources;
    if (_cachedAssessmentSourcesRevision == sourceRevision &&
        _cachedRunId == maintenanceState.runId &&
        identical(_cachedResult, maintenanceState.result) &&
        _cachedStatus == maintenanceState.status) {
      return _cachedAssessments;
    }
    final runAssessments = {
      for (final item
          in maintenanceState.result?.assessments ??
              const <BookSourceMaintenanceAssessment>[])
        item.source.id: item,
    };
    final unpersistedIds =
        !maintenanceState.isRunning && maintenanceState.failure != null
        ? maintenanceState.remainingSources.map((source) => source.id).toSet()
        : const <String>{};
    final merged = <BookSourceMaintenanceAssessment>[];
    for (final source in checkable) {
      final run = runAssessments[source.id];
      final saved = sourceHealthCheckResultOf(source);
      final unsaved = unpersistedIds.contains(source.id);
      if (run != null &&
          !unsaved &&
          (saved == null ||
              run.healthResult == null ||
              !saved.checkedAt.isAfter(run.healthResult!.checkedAt)) &&
          sameBookSourceHealthCheckConfiguration(source, run.source)) {
        merged.add(
          BookSourceMaintenanceAssessment(
            source: source,
            classification: run.classification,
            healthResult: run.healthResult,
            error: run.error,
          ),
        );
      } else {
        merged.add(bookSourceMaintenanceAssessment(source));
      }
    }
    const priority = {
      BookSourceMaintenanceClassification.failed: 0,
      BookSourceMaintenanceClassification.timedOut: 1,
      BookSourceMaintenanceClassification.limited: 2,
      BookSourceMaintenanceClassification.unchecked: 3,
      BookSourceMaintenanceClassification.available: 4,
    };
    merged.sort((a, b) {
      final byClass = priority[a.classification]!.compareTo(
        priority[b.classification]!,
      );
      return byClass != 0 ? byClass : a.source.name.compareTo(b.source.name);
    });
    _cachedAssessmentSourcesRevision = sourceRevision;
    _cachedRunId = maintenanceState.runId;
    _cachedResult = maintenanceState.result;
    _cachedStatus = maintenanceState.status;
    return _cachedAssessments = List.unmodifiable(merged);
  }

  List<BookSourceMaintenanceAssessment> get _visible {
    final query = _search.text.trim().toLowerCase();
    final checkedIds = _checkedOnly ? _currentCheckedIds : const <String>{};
    const problems = {
      BookSourceMaintenanceClassification.limited,
      BookSourceMaintenanceClassification.failed,
      BookSourceMaintenanceClassification.timedOut,
    };
    return _assessments
        .where((item) {
          if (_checkedOnly && !checkedIds.contains(item.source.id)) {
            return false;
          }
          if (_problemsOnly && !problems.contains(item.classification)) {
            return false;
          }
          if (_classification != null &&
              item.classification != _classification) {
            return false;
          }
          if (query.isEmpty) return true;
          final url =
              '${item.source.sourceConfig?['bookSourceUrl'] ?? item.source.apiBaseUrl}';
          return item.source.name.toLowerCase().contains(query) ||
              url.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  String _classificationLabel(BookSourceMaintenanceClassification value) =>
      switch (value) {
        BookSourceMaintenanceClassification.available =>
          context.l10n.bookSourcesMaintenanceAvailable,
        BookSourceMaintenanceClassification.limited =>
          context.l10n.bookSourcesMaintenanceLimited,
        BookSourceMaintenanceClassification.failed =>
          context.l10n.bookSourcesMaintenanceFailed,
        BookSourceMaintenanceClassification.timedOut =>
          context.l10n.bookSourcesMaintenanceTimedOut,
        BookSourceMaintenanceClassification.unchecked =>
          context.l10n.bookSourcesMaintenanceUnchecked,
      };

  String _assessmentDetail(BookSourceMaintenanceAssessment item) =>
      switch (item.classification) {
        BookSourceMaintenanceClassification.timedOut =>
          context.l10n.bookSourcesMaintenanceTimeoutReason,
        BookSourceMaintenanceClassification.unchecked =>
          context.l10n.bookSourcesMaintenanceUncheckedReason,
        BookSourceMaintenanceClassification.available =>
          context.l10n.bookSourcesMaintenanceAvailableReason,
        _ =>
          (item.healthResult?.missingForFullAvailability ?? const {})
              .map(
                (capability) =>
                    sourceHealthCapabilityLabel(context, capability),
              )
              .join(' · '),
      };

  Future<void> _start() async {
    if (_mutationBusy || widget.maintenance.state.isRunning) return;
    setState(() {
      _actionFailure = null;
      _checkedOnly = false;
      _selected.clear();
    });
    final ids = _scopeIds;
    final targets = _checkableSources
        .where((source) => ids.contains(source.id))
        .toList(growable: false);
    if (targets.isEmpty || widget.maintenance.state.isRunning) return;
    try {
      await widget.maintenance.begin(targets);
      if (mounted) await widget.controller.load();
    } on Object catch (error) {
      if (mounted) setState(() => _actionFailure = error);
    }
  }

  Future<void> _resume() async {
    if (_mutationBusy || widget.maintenance.state.isRunning) return;
    setState(() => _actionFailure = null);
    try {
      await widget.maintenance.resume();
      if (mounted) await widget.controller.load();
    } on Object catch (error) {
      if (mounted) setState(() => _actionFailure = error);
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_mutationBusy || widget.maintenance.state.isRunning) return;
    setState(() {
      _busy = true;
      _actionFailure = null;
    });
    try {
      await action();
      if (widget.controller.state.failure case final failure?) {
        if (mounted) setState(() => _actionFailure = failure);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _actionFailure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disableSelected() => _runBusy(() async {
    final enabledIds = widget.controller.state.sources
        .where((source) => source.enabled && _selected.contains(source.id))
        .map((source) => source.id)
        .toSet();
    if (enabledIds.isEmpty) return;
    await widget.controller.disableSources(enabledIds);
    widget.maintenance.reconcileSources(widget.controller.state.sources);
  });

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty ||
        _mutationBusy ||
        widget.maintenance.state.isRunning) {
      return;
    }
    final ids = Set<String>.of(_selected);
    final referencedCount = ids.intersection(_referenced).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesRemoveTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.bookSourcesDeleteSelectedMessage(ids.length)),
            if (referencedCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.bookSourcesMaintenanceDeleteReferencedWarning(
                  referencedCount,
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
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
    if (confirmed != true || !mounted) return;
    await _runBusy(() async {
      await widget.controller.removeSources(ids);
      if (widget.controller.state.failure == null) {
        widget.maintenance.reconcileSources(widget.controller.state.sources);
        _selected.removeAll(ids);
      }
    });
  }

  bool _useWideLayout(BuildContext context, double width) =>
      width >= 800 &&
      MediaQuery.sizeOf(context).height >= 560 &&
      MediaQuery.textScalerOf(context).scale(14) <= 18;

  @override
  Widget build(BuildContext context) {
    final busy = _mutationBusy || widget.maintenance.state.isRunning;
    final visible = _visible;
    final visibleIds = visible.map((item) => item.source.id).toSet();
    _selected.retainAll(visibleIds);
    final canDisable = visible.any(
      (item) => item.source.enabled && _selected.contains(item.source.id),
    );
    return FloatingSubpageScaffold(
      title: context.l10n.bookSourcesMaintenanceTitle,
      maxHeaderWidth: 1320,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = _useWideLayout(context, constraints.maxWidth);
          final results = _resultSlivers(visible, busy, wide: wide);
          if (!wide) {
            return CustomScrollView(
              key: const Key('bookSourceMaintenanceScroll'),
              slivers: [
                SliverPadding(
                  padding: floatingSubpagePadding(context, bottom: 20),
                  sliver: SliverToBoxAdapter(child: _checkControls(busy)),
                ),
                SliverToBoxAdapter(child: _resultTools(visibleIds, busy)),
                ...results,
              ],
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Padding(
                padding: floatingSubpagePadding(
                  context,
                  left: 24,
                  right: 24,
                  bottom: 12,
                ),
                child: Row(
                  key: const Key('maintenanceWideLayout'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: constraints.maxWidth < 1000 ? 240 : 280,
                      child: SingleChildScrollView(
                        key: const Key('maintenanceControlsScroll'),
                        child: _checkControls(busy, wide: true),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            _resultTools(visibleIds, busy, wide: true),
                            Expanded(
                              child: CustomScrollView(
                                key: const Key('bookSourceMaintenanceScroll'),
                                slivers: results,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) {
          final wide = _useWideLayout(context, constraints.maxWidth);
          return Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Padding(
                padding: EdgeInsets.only(
                  left: wide ? (constraints.maxWidth < 1000 ? 288 : 328) : 0,
                  right: wide ? 24 : 0,
                ),
                child: _selectionBar(busy, canDisable),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _checkControls(bool busy, {bool wide = false}) {
    final state = widget.maintenance.state;
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final targets = _scopeIds;
    final statusLabel = switch (state.status) {
      BookSourceMaintenanceStatus.running =>
        l10n.bookSourcesMaintenanceHealthRunning,
      BookSourceMaintenanceStatus.cancelling =>
        l10n.bookSourcesMaintenancePausing,
      BookSourceMaintenanceStatus.cancelled =>
        l10n.bookSourcesMaintenancePaused,
      BookSourceMaintenanceStatus.failed =>
        l10n.bookSourcesMaintenanceFailedTitle,
      BookSourceMaintenanceStatus.completed =>
        l10n.bookSourcesMaintenanceCompleted,
      _ => l10n.bookSourcesMaintenanceHealthTitle,
    };
    final progress = state.progress;
    return Container(
      key: const Key('maintenanceCheckPanel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                state.isRunning
                    ? Icons.radar_rounded
                    : Icons.fact_check_outlined,
                color: scheme.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusLabel,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!wide) _scopeMenu(busy),
            ],
          ),
          const SizedBox(height: 10),
          if (wide)
            Align(alignment: Alignment.centerLeft, child: _scopeMenu(busy)),
          if (progress != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.bookSourcesMaintenanceProgress(
                      progress.completed,
                      progress.total,
                    ),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (state.canResume)
                  Text(
                    l10n.bookSourcesMaintenanceRemaining(
                      state.remainingSources.length,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress.fraction ?? 0,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 10),
          ] else
            Text(
              l10n.bookSourcesMaintenanceCount(targets.length),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          if (state.status == BookSourceMaintenanceStatus.cancelled)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                l10n.bookSourcesMaintenancePausedHint,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (state.isRunning)
                FilledButton.icon(
                  key: const Key('maintenanceStop'),
                  onPressed: state.isCancelling
                      ? null
                      : widget.maintenance.cancel,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: Text(
                    state.isCancelling
                        ? l10n.bookSourcesMaintenancePausing
                        : l10n.bookSourcesMaintenancePause,
                  ),
                )
              else if (state.canResume)
                FilledButton.icon(
                  key: const Key('maintenanceResume'),
                  onPressed: busy ? null : _resume,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(l10n.bookSourcesMaintenanceResume),
                )
              else
                FilledButton.icon(
                  key: const Key('maintenanceStart'),
                  onPressed: busy || targets.isEmpty ? null : _start,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(l10n.bookSourcesMaintenanceStart),
                ),
              if (state.canResume && !state.isRunning)
                TextButton(
                  key: const Key('maintenanceStart'),
                  onPressed: busy || targets.isEmpty ? null : _start,
                  child: Text(l10n.bookSourcesMaintenanceRestart),
                )
              else
                TextButton.icon(
                  key: const Key('maintenanceDedupe'),
                  onPressed: busy || targets.isEmpty
                      ? null
                      : () => _runBusy(() => widget.onDedupe(targets)),
                  icon: const Icon(Icons.content_copy_outlined, size: 16),
                  label: Text(l10n.bookSourcesMaintenanceDedupeTitle),
                ),
            ],
          ),
          if (wide || state.isRunning) ...[
            const SizedBox(height: 12),
            Text(
              state.isRunning
                  ? l10n.bookSourcesMaintenanceBackgroundHint
                  : l10n.bookSourcesMaintenanceHealthSubtitle,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                height: 1.45,
                fontSize: 12,
              ),
            ),
          ],
          if (_actionFailure != null || state.failure != null) ...[
            const SizedBox(height: 12),
            Text(
              _actionFailure != null
                  ? l10n.bookSourcesMaintenanceApplyFailed
                  : l10n.bookSourcesMaintenanceFailedTitle,
              key: const Key('maintenanceActionFailure'),
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _scopeMenu(bool busy) {
    final l10n = context.l10n;
    String label(_MaintenanceScope scope) => switch (scope) {
      _MaintenanceScope.enabled => l10n.bookSourcesMaintenanceScopeEnabled,
      _MaintenanceScope.all => l10n.bookSourcesMaintenanceScopeAll,
      _MaintenanceScope.selected => l10n.bookSourcesMaintenanceScopeSelected,
    };
    return AppPopupMenuButton<_MaintenanceScope>(
      key: const Key('maintenanceScope'),
      enabled: !busy,
      tooltip: l10n.bookSourcesMaintenanceScope,
      initialValue: _scope,
      onSelected: (value) => setState(() => _scope = value),
      itemBuilder: (_) => [
        for (final scope in _MaintenanceScope.values)
          if (scope != _MaintenanceScope.selected ||
              widget.controller.state.selectedSourceIds.isNotEmpty)
            PopupMenuItem(
              value: scope,
              key: Key('maintenanceScope-${scope.name}'),
              child: Text(label(scope)),
            ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label(_scope),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _resultTools(Set<String> visibleIds, bool busy, {bool wide = false}) {
    final l10n = context.l10n;
    final allSelected =
        visibleIds.isNotEmpty && _selected.containsAll(visibleIds);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, wide ? 18 : 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.bookSourcesMaintenanceResultTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                key: const Key('maintenanceSelectVisible'),
                onPressed: visibleIds.isEmpty || busy
                    ? null
                    : () => setState(() {
                        allSelected
                            ? _selected.removeAll(visibleIds)
                            : _selected.addAll(visibleIds);
                      }),
                icon: Icon(
                  allSelected
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded,
                  size: 16,
                ),
                label: Text(
                  allSelected
                      ? l10n.bookSourcesClearSelection
                      : l10n.bookSourcesSelectAll,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('maintenanceResultSearch'),
            controller: _search,
            decoration: InputDecoration(
              hintText: l10n.bookSourcesMaintenanceReviewSearch,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
              filled: true,
              fillColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 12,
                horizontal: 12,
              ),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.bookSourcesClearSelection,
                      onPressed: _search.clear,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          _filterBar(wide: wide),
          const SizedBox(height: 10),
          Divider(
            height: 1,
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _filterBar({bool wide = false}) {
    final l10n = context.l10n;
    final counts = <BookSourceMaintenanceClassification, int>{};
    for (final item in _assessments) {
      counts.update(
        item.classification,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    final checkedIds = _currentCheckedIds;
    Widget filter(
      String key,
      String label,
      bool selected,
      VoidCallback onTap,
    ) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: BookSourcePill(
        key: Key(key),
        label: label,
        selected: selected,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        selectedBackgroundColor: Theme.of(context).colorScheme.primaryContainer,
        selectedForegroundColor: Theme.of(
          context,
        ).colorScheme.onPrimaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        onPressed: () => setState(() {
          _selected.clear();
          onTap();
        }),
      ),
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: Scrollbar(
        controller: _filterScroll,
        thumbVisibility: wide,
        child: SingleChildScrollView(
          key: const Key('maintenanceFiltersScroll'),
          controller: _filterScroll,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(bottom: wide ? 8 : 0),
          child: Row(
            children: [
              if (widget.maintenance.state.result != null)
                filter(
                  'maintenanceFilterChecked',
                  '${l10n.bookSourcesMaintenanceCheckedThisRun} ${checkedIds.length}',
                  _checkedOnly,
                  () {
                    _checkedOnly = true;
                    _problemsOnly = false;
                    _classification = null;
                  },
                ),
              filter(
                'maintenanceFilterAll',
                '${l10n.bookSourcesMaintenanceReviewAll} ${_assessments.length}',
                !_checkedOnly && !_problemsOnly && _classification == null,
                () {
                  _checkedOnly = false;
                  _problemsOnly = false;
                  _classification = null;
                },
              ),
              filter(
                'maintenanceFilterProblems',
                '${l10n.bookSourcesMaintenanceProblemsFilter} ${(counts[BookSourceMaintenanceClassification.failed] ?? 0) + (counts[BookSourceMaintenanceClassification.timedOut] ?? 0) + (counts[BookSourceMaintenanceClassification.limited] ?? 0)}',
                _problemsOnly,
                () {
                  _checkedOnly = false;
                  _problemsOnly = true;
                  _classification = null;
                },
              ),
              for (final category in BookSourceMaintenanceClassification.values)
                if ((counts[category] ?? 0) > 0)
                  filter(
                    'maintenanceResultFilter-${category.name}',
                    '${_classificationLabel(category)} ${counts[category]}',
                    _classification == category,
                    () {
                      _checkedOnly = false;
                      _problemsOnly = false;
                      _classification = category;
                    },
                  ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resultSlivers(
    List<BookSourceMaintenanceAssessment> visible,
    bool busy, {
    required bool wide,
  }) => [
    if (visible.isEmpty)
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(context.l10n.bookSourcesMaintenanceReviewEmpty),
          ),
        ),
      )
    else
      SliverList.builder(
        itemCount: visible.length,
        itemBuilder: (context, index) =>
            _sourceRow(visible[index], busy, wide: wide),
      ),
    const SliverPadding(padding: EdgeInsets.only(bottom: 20)),
  ];

  Widget _sourceRow(
    BookSourceMaintenanceAssessment item,
    bool busy, {
    required bool wide,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final source = item.source;
    final result = item.healthResult;
    final date = result == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatShortDate(result.checkedAt.toLocal());
    final classification = item.classification;
    final color = switch (classification) {
      BookSourceMaintenanceClassification.failed => scheme.error,
      BookSourceMaintenanceClassification.available => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final detail = _assessmentDetail(item);
    final small = TextStyle(
      fontSize: 12,
      color: scheme.onSurfaceVariant,
      height: 1.4,
    );
    return Column(
      children: [
        CheckboxListTile(
          key: Key('maintenanceSource-${source.id}'),
          value: _selected.contains(source.id),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          onChanged: busy
              ? null
              : (value) => setState(() {
                  value == true
                      ? _selected.add(source.id)
                      : _selected.remove(source.id);
                }),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _classificationLabel(classification),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${source.sourceConfig?['bookSourceUrl'] ?? source.apiBaseUrl}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small,
                ),
                if (detail.isNotEmpty) Text(detail, style: small),
                if (_referenced.contains(source.id) || !source.enabled)
                  Text(
                    [
                      if (_referenced.contains(source.id))
                        context.l10n.bookSourcesMaintenanceShelfUsed,
                      if (!source.enabled) context.l10n.bookSourcesDisabled,
                    ].join(' · '),
                    style: small,
                  ),
                if (date != null)
                  Text(
                    '$date${result?.respondTimeMs == null ? '' : ' · ${result!.respondTimeMs} ms'}',
                    style: small.copyWith(fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          indent: 60,
          endIndent: 16,
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ],
    );
  }

  Widget _selectionBar(bool busy, bool canDisable) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 640 ||
                MediaQuery.textScalerOf(context).scale(14) > 18;
            final count = Text(
              l10n.bookSourcesMaintenanceSelectedCount(_selected.length),
              style: Theme.of(context).textTheme.labelMedium,
            );
            final actions = [
              OutlinedButton(
                key: const Key('maintenanceDisableSelected'),
                onPressed: !canDisable || busy ? null : _disableSelected,
                child: Text(l10n.bookSourcesDisableSelected),
              ),
              FilledButton(
                key: const Key('maintenanceDeleteSelected'),
                onPressed: _selected.isEmpty || busy ? null : _deleteSelected,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: Text(l10n.bookSourcesDeleteSelected),
              ),
            ];
            if (compact) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  count,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: actions[0]),
                      const SizedBox(width: 10),
                      Expanded(child: actions[1]),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: count),
                actions[0],
                const SizedBox(width: 10),
                actions[1],
              ],
            );
          },
        ),
      ),
    );
  }
}
