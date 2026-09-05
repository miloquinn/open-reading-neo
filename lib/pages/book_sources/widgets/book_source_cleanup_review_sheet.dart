import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_maintenance_assessment.dart';
import '../../../utils/localization_extension.dart';
import 'book_source_management_source_card.dart';
import 'book_source_pill.dart';

/// Reviews health evidence before returning an explicit set of IDs to disable.
class BookSourceCleanupReviewSheet extends StatefulWidget {
  const BookSourceCleanupReviewSheet({
    super.key,
    required this.fullyAvailableCount,
    required this.needsAttention,
    this.fullyAvailableSources = const [],
    this.assessments = const [],
    this.referencedSourceIds = const {},
  });

  final int fullyAvailableCount;
  final List<RegisteredBookSource> needsAttention;
  final List<RegisteredBookSource> fullyAvailableSources;
  final List<BookSourceMaintenanceAssessment> assessments;
  final Set<String> referencedSourceIds;

  @override
  State<BookSourceCleanupReviewSheet> createState() =>
      _BookSourceCleanupReviewSheetState();
}

class _BookSourceCleanupReviewSheetState
    extends State<BookSourceCleanupReviewSheet> {
  final _selected = <String>{};
  final _search = TextEditingController();
  BookSourceMaintenanceClassification? _filter;
  late final List<BookSourceMaintenanceAssessment> _items = _makeItems();
  late List<BookSourceMaintenanceAssessment> _visible = _items;
  late final Map<BookSourceMaintenanceClassification, int> _counts =
      _countItems();

  Map<BookSourceMaintenanceClassification, int> _countItems() {
    final counts = <BookSourceMaintenanceClassification, int>{};
    for (final item in _items) {
      counts.update(item.classification, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  List<BookSourceMaintenanceAssessment> _makeItems() {
    final overrides = {
      for (final assessment in widget.assessments)
        assessment.source.id: assessment,
    };
    final items = [
      for (final source in [
        ...widget.needsAttention,
        ...widget.fullyAvailableSources,
      ])
        if (overrides[source.id] case final assessment?)
          BookSourceMaintenanceAssessment(
            source: source,
            classification: assessment.classification,
            healthResult: assessment.healthResult,
            error: assessment.error,
          )
        else
          bookSourceMaintenanceAssessment(source),
    ];
    const priority = {
      BookSourceMaintenanceClassification.failed: 0,
      BookSourceMaintenanceClassification.timedOut: 1,
      BookSourceMaintenanceClassification.unchecked: 2,
      BookSourceMaintenanceClassification.limited: 3,
      BookSourceMaintenanceClassification.available: 4,
    };
    items.sort(
      (a, b) =>
          priority[a.classification]!.compareTo(priority[b.classification]!),
    );
    return items;
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(_filterItems);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _filterItems() {
    final query = _search.text.trim().toLowerCase();
    setState(
      () => _visible = _items
          .where((item) {
            if (_filter != null && item.classification != _filter) return false;
            return query.isEmpty ||
                item.source.name.toLowerCase().contains(query) ||
                '${item.source.sourceConfig?['bookSourceUrl'] ?? item.source.apiBaseUrl}'
                    .toLowerCase()
                    .contains(query);
          })
          .toList(growable: false),
    );
  }

  String _label(BookSourceMaintenanceClassification category) =>
      switch (category) {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final counts = _counts;
    final selectedVisible = _visible
        .where((item) => item.source.enabled)
        .every((item) => _selected.contains(item.source.id));
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.84,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.bookSourcesMaintenanceResultTitle,
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
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.bookSourcesCleanupReviewSummary(
                              widget.fullyAvailableCount,
                              widget.needsAttention.length,
                            ),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.bookSourcesCleanupReviewHint,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('maintenanceResultSearch'),
                            controller: _search,
                            decoration: InputDecoration(
                              hintText: l10n.bookSourcesMaintenanceReviewSearch,
                              prefixIcon: const Icon(Icons.search_rounded),
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              suffixIcon: _search.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: l10n.bookSourcesClearSelection,
                                      onPressed: _search.clear,
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 7,
                            runSpacing: 8,
                            children: [
                              BookSourcePill(
                                label:
                                    '${l10n.bookSourcesMaintenanceReviewAll} ${_items.length}',
                                selected: _filter == null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                onPressed: () {
                                  _filter = null;
                                  _filterItems();
                                },
                              ),
                              for (final category
                                  in BookSourceMaintenanceClassification.values)
                                if ((counts[category] ?? 0) > 0)
                                  BookSourcePill(
                                    key: ValueKey(
                                      'maintenanceResultFilter-${category.name}',
                                    ),
                                    label:
                                        '${_label(category)} ${counts[category]}',
                                    selected: _filter == category,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    onPressed: () {
                                      _filter = category;
                                      _filterItems();
                                    },
                                  ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: [
                              TextButton(
                                onPressed: () => setState(() {
                                  _selected.addAll(
                                    _visible
                                        .where(
                                          (item) =>
                                              item.classification ==
                                                  BookSourceMaintenanceClassification
                                                      .failed &&
                                              item.source.enabled &&
                                              !widget.referencedSourceIds
                                                  .contains(item.source.id),
                                        )
                                        .map((item) => item.source.id),
                                  );
                                }),
                                child: Text(
                                  l10n.bookSourcesMaintenanceSelectFailures,
                                ),
                              ),
                              TextButton(
                                onPressed: _visible.isEmpty
                                    ? null
                                    : () => setState(() {
                                        final visibleIds = _visible
                                            .where(
                                              (item) => item.source.enabled,
                                            )
                                            .map((item) => item.source.id);
                                        selectedVisible
                                            ? _selected.removeAll(visibleIds)
                                            : _selected.addAll(visibleIds);
                                      }),
                                child: Text(
                                  selectedVisible
                                      ? l10n.bookSourcesClearSelection
                                      : l10n.bookSourcesSelectAll,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: Divider(height: 1)),
                  if (_visible.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(l10n.bookSourcesMaintenanceReviewEmpty),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: _visible.length,
                      itemBuilder: (context, index) {
                        final item = _visible[index];
                        return _HealthResultRow(
                          assessment: item,
                          label: _label(item.classification),
                          selected: _selected.contains(item.source.id),
                          referenced: widget.referencedSourceIds.contains(
                            item.source.id,
                          ),
                          onChanged: !item.source.enabled
                              ? null
                              : (value) => setState(() {
                                  value
                                      ? _selected.add(item.source.id)
                                      : _selected.remove(item.source.id);
                                }),
                        );
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.bookSourcesMaintenanceReviewSelection(
                      _selected.length,
                    ),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    key: const Key('maintenanceDisableSelected'),
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            Set<String>.unmodifiable(_selected),
                          ),
                    child: Text(
                      l10n.bookSourcesCleanupDisableSelected(_selected.length),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthResultRow extends StatelessWidget {
  const _HealthResultRow({
    required this.assessment,
    required this.label,
    required this.selected,
    required this.referenced,
    required this.onChanged,
  });
  final BookSourceMaintenanceAssessment assessment;
  final String label;
  final bool selected;
  final bool referenced;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final source = assessment.source;
    final result = assessment.healthResult;
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final color =
        assessment.classification == BookSourceMaintenanceClassification.failed
        ? scheme.error
        : scheme.onSurfaceVariant;
    final detail = switch (assessment.classification) {
      BookSourceMaintenanceClassification.timedOut =>
        l10n.bookSourcesMaintenanceTimeoutReason,
      BookSourceMaintenanceClassification.unchecked =>
        l10n.bookSourcesMaintenanceUncheckedReason,
      BookSourceMaintenanceClassification.available =>
        l10n.bookSourcesMaintenanceAvailableReason,
      _ =>
        (result?.missingForFullAvailability ?? {})
            .map((item) => sourceHealthCapabilityLabel(context, item))
            .join(' · '),
    };
    final date = result == null
        ? ''
        : MaterialLocalizations.of(
            context,
          ).formatShortDate(result.checkedAt.toLocal());
    return CheckboxListTile(
      key: ValueKey('bookSourceCleanupItem-${source.id}'),
      value: selected,
      onChanged: onChanged == null
          ? null
          : (value) => onChanged!(value ?? false),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${source.sourceConfig?['bookSourceUrl'] ?? source.apiBaseUrl}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
            const SizedBox(height: 5),
            Text(
              '$label${detail.isEmpty ? '' : ' · $detail'}',
              style: TextStyle(color: color, height: 1.4, fontSize: 12),
            ),
            if (referenced)
              Text(
                l10n.bookSourcesMaintenanceShelfProtected,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            if (!source.enabled)
              Text(
                l10n.bookSourcesDisabled,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
            if (date.isNotEmpty)
              Text(
                '$date${result?.respondTimeMs == null ? '' : ' · ${result!.respondTimeMs} ms'}',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
