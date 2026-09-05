import 'package:flutter/material.dart';

import '../../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../../utils/localization_extension.dart';

class BookSourceMaintenanceProgressSheet extends StatelessWidget {
  const BookSourceMaintenanceProgressSheet({
    super.key,
    required this.maintenance,
    required this.onReview,
  });
  final BookSourceMaintenanceCoordinator maintenance;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: maintenance,
    builder: (context, _) {
      final state = maintenance.state;
      final l10n = context.l10n;
      final scheme = Theme.of(context).colorScheme;
      final running = state.isRunning;
      final result = state.result;
      final completed = state.progress?.completed ?? result?.total ?? 0;
      final total = state.progress?.total ?? result?.total ?? 0;
      final title = switch (state.status) {
        BookSourceMaintenanceStatus.running =>
          l10n.bookSourcesMaintenanceProgressTitle,
        BookSourceMaintenanceStatus.cancelling =>
          l10n.bookSourcesMaintenanceCancellingTitle,
        BookSourceMaintenanceStatus.cancelled =>
          l10n.bookSourcesMaintenanceCancelledTitle,
        BookSourceMaintenanceStatus.failed =>
          l10n.bookSourcesMaintenanceFailedTitle,
        _ => l10n.bookSourcesMaintenanceFinishedTitle,
      };
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
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.bookSourcesCancel,
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Text(
                state.isCancelling
                    ? l10n.bookSourcesMaintenanceCancellingHint
                    : running
                    ? l10n.bookSourcesMaintenanceProgressHint
                    : l10n.bookSourcesMaintenanceFinishedSummary(
                        result?.total ?? 0,
                        result?.needsAttention.length ?? 0,
                      ),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 22),
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.bookSourcesMaintenanceProgress(completed, total),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (total > 0)
                      Text(
                        '${(completed / total * 100).clamp(0, 100).round()}%',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: total > 0
                    ? (completed / total).clamp(0.0, 1.0)
                    : running
                    ? null
                    : 0,
                minHeight: 6,
                borderRadius: BorderRadius.circular(4),
              ),
              if (!running && state.remainingSources.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.bookSourcesMaintenanceRemaining(
                    state.remainingSources.length,
                  ),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
              if (state.failure != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${state.failure}',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              if (running) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        key: const Key('bookSourcesMaintenanceStopButton'),
                        onPressed: state.isCancelling
                            ? null
                            : maintenance.cancel,
                        child: Text(l10n.bookSourcesMaintenanceStop),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key(
                          'bookSourcesMaintenanceBackgroundButton',
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(l10n.bookSourcesMaintenanceBackground),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.bookSourcesMaintenanceBackgroundHint,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ] else ...[
                if (state.canResume)
                  FilledButton.icon(
                    key: const Key('bookSourcesMaintenanceResumeButton'),
                    onPressed: () => maintenance.resume(),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(l10n.bookSourcesMaintenanceResume),
                  ),
                if (result != null && result.total > 0)
                  Padding(
                    padding: EdgeInsets.only(top: state.canResume ? 8 : 0),
                    child: FilledButton.tonalIcon(
                      key: const Key('bookSourcesMaintenanceReviewButton'),
                      onPressed: onReview,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(l10n.bookSourcesMaintenanceReviewResults),
                    ),
                  ),
                if (!state.canResume && state.hasReviewResult)
                  TextButton(
                    onPressed: () => maintenance.retryIssues(),
                    child: Text(l10n.bookSourcesMaintenanceRetry),
                  ),
                if (!state.canResume &&
                    result?.total != null &&
                    result!.total == 0)
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.bookSourcesConfirm),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
