part of 'book_source_management_page.dart';

extension _BookSourceManagementMaintenance on _BookSourceManagementPageState {
  Future<void> _showMaintenanceMenu() async {
    if (_maintenancePageOpen || !mounted) return;
    _maintenancePageOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => BookSourceMaintenancePage(
            controller: _controller,
            maintenance: _maintenance,
            readReferencedSourceIds: widget.readReferencedSourceIds,
            onDedupe: (ids) => _reviewInstalledDuplicates(sourceIds: ids),
          ),
        ),
      );
    } finally {
      _maintenancePageOpen = false;
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
