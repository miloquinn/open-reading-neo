import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/source_engine/source_health_checker.dart';
import '../../../utils/localization_extension.dart';
import 'book_source_management_source_card.dart';

/// Shown after a cleanup sweep to let the user review which sources didn't
/// come back fully available before any of them get disabled. Returns the
/// set of source ids to disable, or null if the user cancelled.
class BookSourceCleanupReviewSheet extends StatefulWidget {
  const BookSourceCleanupReviewSheet({
    super.key,
    required this.fullyAvailableCount,
    required this.needsAttention,
  });

  final int fullyAvailableCount;
  final List<RegisteredBookSource> needsAttention;

  @override
  State<BookSourceCleanupReviewSheet> createState() =>
      _BookSourceCleanupReviewSheetState();
}

class _BookSourceCleanupReviewSheetState
    extends State<BookSourceCleanupReviewSheet> {
  late Set<String> _selected = widget.needsAttention
      .map((source) => source.id)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected = _selected.length == widget.needsAttention.length;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              context.l10n.bookSourcesCleanupReviewTitle,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              context.l10n.bookSourcesCleanupReviewSummary(
                widget.fullyAvailableCount,
                widget.needsAttention.length,
              ),
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.bookSourcesCleanupReviewHint,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selected = allSelected
                        ? const {}
                        : widget.needsAttention
                              .map((source) => source.id)
                              .toSet();
                  }),
                  child: Text(
                    allSelected
                        ? context.l10n.bookSourcesClearSelection
                        : context.l10n.bookSourcesSelectAll,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: widget.needsAttention.length,
              itemBuilder: (context, index) {
                final source = widget.needsAttention[index];
                final missing =
                    sourceHealthCheckResultOf(
                      source,
                    )?.missingForFullAvailability ??
                    const <SourceHealthCapability>{};
                final subtitle = missing
                    .map(
                      (capability) =>
                          sourceHealthCapabilityLabel(context, capability),
                    )
                    .join(', ');
                return CheckboxListTile(
                  key: ValueKey('bookSourceCleanupItem-${source.id}'),
                  value: _selected.contains(source.id),
                  onChanged: (value) => setState(() {
                    if (value ?? false) {
                      _selected.add(source.id);
                    } else {
                      _selected.remove(source.id);
                    }
                  }),
                  title: Text(source.name, overflow: TextOverflow.ellipsis),
                  subtitle: subtitle.isEmpty
                      ? null
                      : Text(
                          subtitle,
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.l10n.bookSourcesCancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: Text(
                      context.l10n.bookSourcesCleanupDisableSelected(
                        _selected.length,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
