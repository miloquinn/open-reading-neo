part of 'book_source_management_page.dart';

extension _BookSourceManagementMaintenance on _BookSourceManagementPageState {
  Future<void> _showMaintenanceMenu() async {
    final request = await showModalBottomSheet<BookSourceMaintenanceRequest>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => BookSourceMaintenanceSheet(
        maintenance: _maintenance,
        sources: _controller.state.sources,
        selectedSourceIds: _controller.state.selectedSourceIds,
      ),
    );
    if (!mounted || request == null) return;
    switch (request.action) {
      case BookSourceMaintenanceAction.healthCheck:
        if (!_maintenance.state.isRunning) {
          unawaited(
            _maintenance.start(
              _controller.state.sources.where(
                (source) => request.sourceIds.contains(source.id),
              ),
            ),
          );
        }
        await _showMaintenanceProgress();
      case BookSourceMaintenanceAction.dedupe:
        await _reviewInstalledDuplicates(sourceIds: request.sourceIds);
      case BookSourceMaintenanceAction.reviewHealthResult:
        await _reviewHealthResult();
      case BookSourceMaintenanceAction.resumeHealth:
        unawaited(_maintenance.resume());
        await _showMaintenanceProgress();
      case BookSourceMaintenanceAction.retryHealth:
        unawaited(_maintenance.retryIssues());
        await _showMaintenanceProgress();
    }
  }

  Future<void> _showMaintenanceProgress() async {
    if (_maintenanceProgressOpen || !mounted) return;
    _maintenanceProgressOpen = true;
    var reviewAfterClose = false;
    try {
      final continued = await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => BookSourceMaintenanceProgressSheet(
          maintenance: _maintenance,
          onReview: () {
            reviewAfterClose = true;
            Navigator.pop(sheetContext, false);
          },
        ),
      );
      if (!mounted) return;
      if (reviewAfterClose) {
        await _reviewHealthResult();
      } else if (continued != false && _maintenance.state.isRunning) {
        showSideToast(
          context,
          context.l10n.bookSourcesMaintenanceBackgroundToast,
          kind: SideToastKind.info,
        );
      }
    } finally {
      _maintenanceProgressOpen = false;
    }
  }

  Future<void> _reviewHealthResult() async {
    final result = _maintenance.state.result;
    if (result == null) return;
    if (result.total == 0) {
      showSideToast(
        context,
        context.l10n.bookSourcesCleanupNoCheckableSources,
        kind: SideToastKind.info,
      );
      return;
    }
    try {
      final references = await widget.readReferencedSourceIds();
      if (!mounted) return;
      final current = {
        for (final source in _controller.state.sources) source.id: source,
      };
      // A background check may outlive edits or removal in the source list.
      final attention = [
        for (final assessment in result.assessments)
          if (assessment.needsAttention &&
              !result.reviewedSourceIds.contains(assessment.source.id))
            ?current[assessment.source.id],
      ];
      final available = [
        for (final source in result.fullyAvailable) ?current[source.id],
      ];
      final toDisable = await showModalBottomSheet<Set<String>>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => BookSourceCleanupReviewSheet(
          fullyAvailableCount: available.length,
          fullyAvailableSources: available,
          needsAttention: attention,
          assessments: result.assessments,
          referencedSourceIds: references,
        ),
      );
      if (!mounted || toDisable == null || toDisable.isEmpty) return;
      final applied = await _applyMaintenanceSelection(toDisable);
      if (applied.isNotEmpty) await _maintenance.dismissReviewed(applied);
    } on Object catch (error) {
      if (mounted) showSideToast(context, '$error', kind: SideToastKind.error);
    }
  }

  Future<Set<String>> _applyMaintenanceSelection(
    Set<String> selected, {
    bool duplicates = false,
  }) async {
    final ids = _controller.state.sources
        .where((source) => source.enabled && selected.contains(source.id))
        .map((source) => source.id)
        .toSet();
    if (ids.isEmpty) return const {};
    await _controller.disableSources(ids);
    if (!mounted) return const {};
    final applied = _controller.state.sources
        .where((source) => !source.enabled && ids.contains(source.id))
        .map((source) => source.id)
        .toSet();
    showSideToast(
      context,
      duplicates
          ? context.l10n.bookSourcesDedupeDisabledSummary(applied.length)
          : context.l10n.bookSourcesCleanupDisabledSummary(applied.length),
      kind: SideToastKind.success,
    );
    return applied;
  }

  Future<void> _reviewInstalledDuplicates({Set<String>? sourceIds}) async {
    if (_dedupeRunning) return;
    _dedupeRunning = true;
    try {
      final analysis =
          await showModalBottomSheet<BookSourceInstalledDedupeResult>(
            context: context,
            useSafeArea: true,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => _InstalledDedupeScanSheet(
              scan: () async {
                final references = await widget.readReferencedSourceIds();
                return _controller.findDuplicateSourcesInBackground(
                  sourceIds: sourceIds,
                  referencedSourceIds: references,
                );
              },
            ),
          );
      if (!mounted || analysis == null) return;
      final actionable = analysis.result.groups.any(
        (group) => group.candidates.any(
          (candidate) =>
              candidate.index != group.recommendedIndex &&
              analysis.sourcesByIndex[candidate.index]!.enabled,
        ),
      );
      if (!actionable) {
        showSideToast(
          context,
          context.l10n.bookSourcesDedupeNone,
          kind: SideToastKind.info,
        );
        return;
      }
      final toDisable = await showModalBottomSheet<Set<String>>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => BookSourceInstalledDedupeReviewSheet(
          result: analysis.result,
          sourcesByIndex: analysis.sourcesByIndex,
        ),
      );
      if (!mounted || toDisable == null || toDisable.isEmpty) return;
      await _applyMaintenanceSelection(toDisable, duplicates: true);
    } on Object catch (error) {
      if (mounted) showSideToast(context, '$error', kind: SideToastKind.error);
    } finally {
      _dedupeRunning = false;
    }
  }
}

class _InstalledDedupeScanSheet extends StatefulWidget {
  const _InstalledDedupeScanSheet({required this.scan});
  final Future<BookSourceInstalledDedupeResult> Function() scan;
  @override
  State<_InstalledDedupeScanSheet> createState() =>
      _InstalledDedupeScanSheetState();
}

class _InstalledDedupeScanSheetState extends State<_InstalledDedupeScanSheet> {
  Object? _failure;
  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    if (mounted) setState(() => _failure = null);
    // Allow the progress surface to paint before preparing the worker input.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      final result = await widget.scan();
      if (mounted) Navigator.pop(context, result);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.bookSourcesMaintenanceDedupeTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            _failure == null
                ? context.l10n.bookSourcesMaintenanceDedupeBusy
                : '$_failure',
          ),
          const SizedBox(height: 16),
          if (_failure == null)
            const LinearProgressIndicator()
          else
            FilledButton(
              onPressed: _scan,
              child: Text(context.l10n.bookSourcesMaintenanceRetry),
            ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesCancel),
          ),
        ],
      ),
    ),
  );
}
