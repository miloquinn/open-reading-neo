import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../../utils/localization_extension.dart';
import 'book_source_pill.dart';

export 'book_source_maintenance_progress_sheet.dart';

enum BookSourceMaintenanceAction {
  healthCheck,
  dedupe,
  reviewHealthResult,
  resumeHealth,
  retryHealth,
}

enum BookSourceMaintenanceScope { enabled, all, selected }

class BookSourceMaintenanceRequest {
  const BookSourceMaintenanceRequest(this.action, this.sourceIds);
  final BookSourceMaintenanceAction action;
  final Set<String> sourceIds;
}

class BookSourceMaintenanceSheet extends StatefulWidget {
  const BookSourceMaintenanceSheet({
    super.key,
    required this.maintenance,
    this.sources = const [],
    this.selectedSourceIds = const {},
  });

  final BookSourceMaintenanceCoordinator maintenance;
  final List<RegisteredBookSource> sources;
  final Set<String> selectedSourceIds;

  @override
  State<BookSourceMaintenanceSheet> createState() =>
      _BookSourceMaintenanceSheetState();
}

class _BookSourceMaintenanceSheetState
    extends State<BookSourceMaintenanceSheet> {
  late BookSourceMaintenanceScope _scope = widget.selectedSourceIds.isEmpty
      ? BookSourceMaintenanceScope.enabled
      : BookSourceMaintenanceScope.selected;
  late List<RegisteredBookSource> _eligible = _eligibleSources();
  final _scopeCache =
      <BookSourceMaintenanceScope, List<RegisteredBookSource>>{};

  List<RegisteredBookSource> _eligibleSources() => widget.sources
      .where(
        (source) =>
            source.sourceProtocol == BookSourceProtocolKind.readingSource,
      )
      .toList(growable: false);

  @override
  void didUpdateWidget(covariant BookSourceMaintenanceSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sources, widget.sources) ||
        !identical(oldWidget.selectedSourceIds, widget.selectedSourceIds)) {
      _eligible = _eligibleSources();
      _scopeCache.clear();
    }
  }

  List<RegisteredBookSource> _sourcesFor(BookSourceMaintenanceScope scope) =>
      _scopeCache.putIfAbsent(
        scope,
        () => _eligible
            .where(
              (source) => switch (scope) {
                BookSourceMaintenanceScope.enabled => source.enabled,
                BookSourceMaintenanceScope.all => true,
                BookSourceMaintenanceScope.selected =>
                  widget.selectedSourceIds.contains(source.id),
              },
            )
            .toList(growable: false),
      );

  void _open(BookSourceMaintenanceAction action) => Navigator.pop(
    context,
    BookSourceMaintenanceRequest(
      action,
      _sourcesFor(_scope).map((source) => source.id).toSet(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: widget.maintenance,
      builder: (context, _) {
        final state = widget.maintenance.state;
        final count = _sourcesFor(_scope).length;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.bookSourcesMaintenanceTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.bookSourcesCancel,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  l10n.bookSourcesMaintenanceSubtitle,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 22),
                Text(
                  l10n.bookSourcesMaintenanceScope,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final scope in BookSourceMaintenanceScope.values)
                      if (scope != BookSourceMaintenanceScope.selected ||
                          widget.selectedSourceIds.isNotEmpty)
                        BookSourcePill(
                          key: ValueKey('maintenanceScope-${scope.name}'),
                          label:
                              '${switch (scope) {
                                BookSourceMaintenanceScope.enabled => l10n.bookSourcesMaintenanceScopeEnabled,
                                BookSourceMaintenanceScope.all => l10n.bookSourcesMaintenanceScopeAll,
                                BookSourceMaintenanceScope.selected => l10n.bookSourcesMaintenanceScopeSelected,
                              }} ${_sourcesFor(scope).length}',
                          selected: _scope == scope,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          onPressed: state.isRunning
                              ? null
                              : () => setState(() => _scope = scope),
                        ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  count == 0
                      ? l10n.bookSourcesMaintenanceEmptyScope
                      : l10n.bookSourcesMaintenanceCount(count),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 20),
                _MaintenanceActionTile(
                  key: const Key('bookSourcesDedupeMaintenanceAction'),
                  icon: Icons.difference_outlined,
                  title: l10n.bookSourcesMaintenanceDedupeTitle,
                  subtitle: l10n.bookSourcesMaintenanceDedupeSubtitle,
                  category: l10n.bookSourcesMaintenanceLocalLabel,
                  onTap: count == 0 || state.isRunning
                      ? null
                      : () => _open(BookSourceMaintenanceAction.dedupe),
                ),
                const Divider(height: 25),
                _MaintenanceActionTile(
                  key: const Key('bookSourcesHealthMaintenanceAction'),
                  icon: Icons.health_and_safety_outlined,
                  title: state.isRunning
                      ? l10n.bookSourcesMaintenanceHealthRunning
                      : l10n.bookSourcesMaintenanceHealthTitle,
                  subtitle: state.isRunning
                      ? l10n.bookSourcesMaintenanceProgress(
                          state.progress?.completed ?? 0,
                          state.progress?.total ?? 0,
                        )
                      : l10n.bookSourcesMaintenanceHealthSubtitle,
                  category: l10n.bookSourcesMaintenanceNetworkLabel,
                  onTap: count == 0 && !state.isRunning
                      ? null
                      : () => _open(BookSourceMaintenanceAction.healthCheck),
                ),
                if (state.isRunning) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: state.progress?.fraction,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
                if (!state.isRunning &&
                    (state.result != null || state.failure != null)) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(switch (state.status) {
                          BookSourceMaintenanceStatus.failed =>
                            l10n.bookSourcesMaintenanceFailedTitle,
                          BookSourceMaintenanceStatus.cancelled =>
                            l10n.bookSourcesMaintenanceCancelledTitle,
                          _ => l10n.bookSourcesMaintenanceReviewTitle,
                        }, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 5),
                        Text(
                          l10n.bookSourcesMaintenanceFinishedSummary(
                            state.progress?.completed ??
                                state.result?.total ??
                                0,
                            state.result?.needsAttention.length ?? 0,
                          ),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        if (state.canResume) ...[
                          const SizedBox(height: 4),
                          Text(
                            l10n.bookSourcesMaintenanceRemaining(
                              state.remainingSources.length,
                            ),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (state.result != null && state.result!.total > 0)
                              TextButton.icon(
                                key: const Key(
                                  'bookSourcesMaintenanceReviewAction',
                                ),
                                onPressed: () => _open(
                                  BookSourceMaintenanceAction
                                      .reviewHealthResult,
                                ),
                                icon: const Icon(
                                  Icons.fact_check_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  l10n.bookSourcesMaintenanceReviewResults,
                                ),
                              ),
                            if (state.canResume)
                              TextButton(
                                onPressed: () => _open(
                                  BookSourceMaintenanceAction.resumeHealth,
                                ),
                                child: Text(l10n.bookSourcesMaintenanceResume),
                              )
                            else if (state.hasReviewResult)
                              TextButton(
                                onPressed: () => _open(
                                  BookSourceMaintenanceAction.retryHealth,
                                ),
                                child: Text(l10n.bookSourcesMaintenanceRetry),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  l10n.bookSourcesMaintenanceSafetyHint,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MaintenanceActionTile extends StatelessWidget {
  const _MaintenanceActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                icon,
                size: 24,
                color: onTap == null ? scheme.onSurfaceVariant : scheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
