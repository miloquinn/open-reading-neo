import 'package:flutter/material.dart';

import '../../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../../utils/localization_extension.dart';

enum BookSourceMaintenanceAction { healthCheck, dedupe, reviewHealthResult }

class BookSourceMaintenanceSheet extends StatelessWidget {
  const BookSourceMaintenanceSheet({super.key, required this.maintenance});

  final BookSourceMaintenanceCoordinator maintenance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = maintenance.state;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.bookSourcesMaintenanceTitle,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.bookSourcesMaintenanceSubtitle,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 18),
            _MaintenanceActionTile(
              key: const Key('bookSourcesHealthMaintenanceAction'),
              icon: state.isRunning
                  ? Icons.monitor_heart_rounded
                  : Icons.health_and_safety_outlined,
              title: state.isRunning
                  ? context.l10n.bookSourcesMaintenanceHealthRunning
                  : context.l10n.bookSourcesMaintenanceHealthTitle,
              subtitle: state.isRunning
                  ? context.l10n.bookSourcesMaintenanceProgress(
                      state.progress?.completed ?? 0,
                      state.progress?.total ?? 0,
                    )
                  : context.l10n.bookSourcesMaintenanceHealthSubtitle,
              accent: scheme.primary,
              trailing: state.isRunning
                  ? SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        value: state.progress?.fraction,
                        strokeWidth: 2.5,
                      ),
                    )
                  : null,
              onTap: () => Navigator.pop(
                context,
                BookSourceMaintenanceAction.healthCheck,
              ),
            ),
            const SizedBox(height: 10),
            _MaintenanceActionTile(
              key: const Key('bookSourcesDedupeMaintenanceAction'),
              icon: Icons.difference_outlined,
              title: context.l10n.bookSourcesMaintenanceDedupeTitle,
              subtitle: context.l10n.bookSourcesMaintenanceDedupeSubtitle,
              accent: scheme.tertiary,
              onTap: () =>
                  Navigator.pop(context, BookSourceMaintenanceAction.dedupe),
            ),
            if (!state.isRunning && state.hasReviewResult) ...[
              const SizedBox(height: 10),
              _MaintenanceActionTile(
                key: const Key('bookSourcesMaintenanceReviewAction'),
                icon: Icons.fact_check_outlined,
                title: context.l10n.bookSourcesMaintenanceReviewTitle,
                subtitle: context.l10n.bookSourcesMaintenanceReviewSubtitle(
                  state.result!.needsAttention.length,
                ),
                accent: scheme.error,
                onTap: () => Navigator.pop(
                  context,
                  BookSourceMaintenanceAction.reviewHealthResult,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.bookSourcesMaintenanceSafetyHint,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.4,
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

class BookSourceMaintenanceProgressSheet extends StatelessWidget {
  const BookSourceMaintenanceProgressSheet({
    super.key,
    required this.maintenance,
    required this.onReview,
  });

  final BookSourceMaintenanceCoordinator maintenance;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: AnimatedBuilder(
        animation: maintenance,
        builder: (context, _) {
          final state = maintenance.state;
          final progress = state.progress;
          final result = state.result;
          final running = state.isRunning;
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          running
                              ? Icons.monitor_heart_rounded
                              : Icons.fact_check_outlined,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              running
                                  ? context
                                        .l10n
                                        .bookSourcesMaintenanceProgressTitle
                                  : context
                                        .l10n
                                        .bookSourcesMaintenanceFinishedTitle,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              running
                                  ? context
                                        .l10n
                                        .bookSourcesMaintenanceProgressHint
                                  : context.l10n
                                        .bookSourcesMaintenanceFinishedSummary(
                                          result?.total ?? 0,
                                          result?.needsAttention.length ?? 0,
                                        ),
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(
                    value: running ? progress?.fraction : 1,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    running
                        ? context.l10n.bookSourcesMaintenanceProgress(
                            progress?.completed ?? 0,
                            progress?.total ?? 0,
                          )
                        : context.l10n.bookSourcesMaintenanceProgress(
                            result?.total ?? 0,
                            result?.total ?? 0,
                          ),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 18),
                  if (running)
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            key: const Key('bookSourcesMaintenanceStopButton'),
                            onPressed: () {
                              maintenance.cancel();
                              Navigator.pop(context, false);
                            },
                            child: Text(
                              context.l10n.bookSourcesMaintenanceStop,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key(
                              'bookSourcesMaintenanceBackgroundButton',
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            label: Text(
                              context.l10n.bookSourcesMaintenanceBackground,
                            ),
                          ),
                        ),
                      ],
                    )
                  else if (state.hasReviewResult)
                    FilledButton.icon(
                      key: const Key('bookSourcesMaintenanceReviewButton'),
                      onPressed: onReview,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(
                        context.l10n.bookSourcesMaintenanceReviewResults,
                      ),
                    )
                  else
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.l10n.bookSourcesConfirm),
                    ),
                  if (running) ...[
                    const SizedBox(height: 10),
                    Text(
                      context.l10n.bookSourcesMaintenanceBackgroundHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MaintenanceActionTile extends StatelessWidget {
  const _MaintenanceActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
