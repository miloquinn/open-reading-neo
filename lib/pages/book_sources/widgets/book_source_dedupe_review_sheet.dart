import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../book_sources/dedupe/book_source_dedupe_engine.dart';
import '../../../book_sources/dedupe/book_source_dedupe_models.dart';
import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/source_engine/source_import_service.dart';
import '../../../utils/localization_extension.dart';

class BookSourceImportDedupeSelection {
  const BookSourceImportDedupeSelection({
    required this.mode,
    required this.selectedIndices,
    this.preview,
  });

  final BookSourceDedupeMode mode;
  final Set<int> selectedIndices;
  final SourceImportPreview? preview;
}

class BookSourceImportDedupeReviewSheet extends StatefulWidget {
  const BookSourceImportDedupeReviewSheet({super.key, required this.preview});

  final SourceImportPreview preview;

  @override
  State<BookSourceImportDedupeReviewSheet> createState() =>
      _BookSourceImportDedupeReviewSheetState();
}

class _BookSourceImportDedupeReviewSheetState
    extends State<BookSourceImportDedupeReviewSheet> {
  late SourceImportPreview _preview = widget.preview;
  late List<_DedupeRow> _rows = _reviewRows(_preview.dedupeResult.groups);
  late Set<int> _selected = _preview.selectedIndices.toSet();

  bool _analyzing = false;
  Object? _failure;

  Future<void> _setMode(BookSourceDedupeMode mode) async {
    if (_analyzing || mode == _preview.mode) return;
    setState(() {
      _analyzing = true;
      _failure = null;
    });
    try {
      final preview = await compute(_changeImportMode, (
        preview: _preview,
        mode: mode,
      ));
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _rows = _reviewRows(preview.dedupeResult.groups);
        _selected = preview.selectedIndices.toSet();
      });
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DedupeSheetFrame(
      title: context.l10n.bookSourcesDedupeReviewTitle,
      summary: context.l10n.bookSourcesDedupeReviewSummary(
        _preview.dedupeResult.groups.length,
        _preview.dedupeResult.duplicateCandidateCount,
      ),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeSelector(
            mode: _preview.mode,
            onChanged: _analyzing ? null : _setMode,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _analyzing
                ? null
                : () => setState(() {
                    _selected = _preview.dedupeResult.defaultSelectedIndices
                        .toSet();
                  }),
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(context.l10n.bookSourcesDedupeRestoreDefaults),
          ),
        ],
      ),
      busy: _analyzing,
      failure: _failure,
      groupCount: _rows.length,
      groupBuilder: (context, rowIndex) {
        final row = _rows[rowIndex];
        final group = row.group;
        final candidate = row.candidate;
        if (candidate == null) return _DedupeGroupHeader(group: group);
        void select(bool value) => setState(() {
          if (group.requiresReview) {
            value
                ? _selected.add(candidate.index)
                : _selected.remove(candidate.index);
          } else {
            _selected.removeAll(group.candidates.map((item) => item.index));
            _selected.add(candidate.index);
          }
        });
        final title = Text(
          candidate.name.isEmpty ? candidate.identity.raw : candidate.name,
        );
        final subtitle = _CandidateSubtitle(
          url: candidate.identity.raw,
          recommended: candidate.index == group.recommendedIndex,
        );
        if (group.requiresReview) {
          return CheckboxListTile(
            value: _selected.contains(candidate.index),
            onChanged: (value) => select(value ?? false),
            title: title,
            subtitle: subtitle,
          );
        }
        return RadioGroup<int>(
          groupValue: _selected.contains(candidate.index)
              ? candidate.index
              : null,
          onChanged: (value) {
            if (value != null) select(true);
          },
          child: RadioListTile<int>(
            value: candidate.index,
            title: title,
            subtitle: subtitle,
          ),
        );
      },
      actionLabel: context.l10n.bookSourcesConfirm,
      onConfirm: _analyzing
          ? null
          : () => Navigator.pop(
              context,
              BookSourceImportDedupeSelection(
                mode: _preview.mode,
                selectedIndices: Set.unmodifiable(_selected),
                preview: _preview.withSelectedIndices(_selected),
              ),
            ),
    );
  }
}

class BookSourceInstalledDedupeReviewSheet extends StatefulWidget {
  const BookSourceInstalledDedupeReviewSheet({
    super.key,
    required this.result,
    required this.sourcesByIndex,
  });

  final BookSourceDedupeResult result;
  final Map<int, RegisteredBookSource> sourcesByIndex;

  @override
  State<BookSourceInstalledDedupeReviewSheet> createState() =>
      _BookSourceInstalledDedupeReviewSheetState();
}

class _BookSourceInstalledDedupeReviewSheetState
    extends State<BookSourceInstalledDedupeReviewSheet> {
  late BookSourceDedupeResult _result = widget.result;
  late List<_DedupeRow> _rows = _reviewRows(_result.groups, installed: true);
  late Set<String> _selected = _defaultSelection(_result);

  Set<String> _defaultSelection(BookSourceDedupeResult result) => {
    for (final group in result.groups)
      if (!group.requiresReview &&
          widget.sourcesByIndex[group.recommendedIndex]!.enabled)
        for (final candidate in group.candidates)
          if (candidate.index != group.recommendedIndex &&
              !candidate.isReferenced &&
              widget.sourcesByIndex[candidate.index]!.enabled)
            widget.sourcesByIndex[candidate.index]!.id,
  };

  bool _analyzing = false;
  Object? _failure;

  Future<void> _setMode(BookSourceDedupeMode mode) async {
    if (_analyzing || mode == _result.mode) return;
    setState(() {
      _analyzing = true;
      _failure = null;
    });
    try {
      final result = await compute(_changeInstalledMode, (
        candidates: widget.result.candidates,
        mode: mode,
      ));
      if (!mounted) return;
      setState(() {
        _result = result;
        _rows = _reviewRows(result.groups, installed: true);
        _selected = _defaultSelection(result);
      });
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DedupeSheetFrame(
      title: context.l10n.bookSourcesDedupeReviewTitle,
      summary: context.l10n.bookSourcesDedupeReviewSummary(
        _result.groups.length,
        _result.duplicateCandidateCount,
      ),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeSelector(
            mode: _result.mode,
            onChanged: _analyzing ? null : _setMode,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.bookSourcesDedupeReviewHint,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
      busy: _analyzing,
      failure: _failure,
      groupCount: _rows.length,
      groupBuilder: (context, rowIndex) {
        final row = _rows[rowIndex];
        final candidate = row.candidate;
        if (candidate == null) {
          return _DedupeGroupHeader(
            group: row.group,
            winner: widget.sourcesByIndex[row.group.recommendedIndex],
          );
        }
        final source = widget.sourcesByIndex[candidate.index]!;
        return CheckboxListTile(
          key: ValueKey('installedDedupe-${source.id}'),
          value: _selected.contains(source.id),
          onChanged: !source.enabled
              ? null
              : (value) => setState(() {
                  (value ?? false)
                      ? _selected.add(source.id)
                      : _selected.remove(source.id);
                }),
          title: Text(source.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                candidate.identity.raw,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (candidate.isReferenced)
                Text(
                  context.l10n.bookSourcesMaintenanceShelfProtected,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              if (!source.enabled) Text(context.l10n.bookSourcesDisabled),
            ],
          ),
        );
      },
      actionLabel: context.l10n.bookSourcesDedupeDisableSelected(
        _selected.length,
      ),
      onConfirm: _analyzing || _selected.isEmpty
          ? null
          : () => Navigator.pop(context, Set.unmodifiable(_selected)),
    );
  }
}

class _DedupeSheetFrame extends StatelessWidget {
  const _DedupeSheetFrame({
    required this.title,
    required this.summary,
    required this.header,
    required this.groupCount,
    required this.groupBuilder,
    required this.actionLabel,
    required this.onConfirm,
    this.busy = false,
    this.failure,
  });

  final String title;
  final String summary;
  final Widget header;
  final int groupCount;
  final IndexedWidgetBuilder groupBuilder;
  final String actionLabel;
  final VoidCallback? onConfirm;
  final bool busy;
  final Object? failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.86,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(summary, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                header,
                if (busy) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(context.l10n.bookSourcesImportAnalyzing),
                  ),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
                if (failure != null)
                  Text(
                    '$failure',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: IgnorePointer(
              ignoring: busy,
              child: groupCount == 0
                  ? Center(child: Text(context.l10n.bookSourcesDedupeNone))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: groupCount,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: groupBuilder,
                    ),
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
                    onPressed: onConfirm,
                    child: Text(actionLabel),
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

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});

  final BookSourceDedupeMode mode;
  final ValueChanged<BookSourceDedupeMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<BookSourceDedupeMode>(
      segments: [
        ButtonSegment(
          value: BookSourceDedupeMode.exact,
          label: Text(context.l10n.bookSourcesDedupeModeExact),
        ),
        ButtonSegment(
          value: BookSourceDedupeMode.standard,
          label: Text(context.l10n.bookSourcesDedupeModeStandard),
        ),
        ButtonSegment(
          value: BookSourceDedupeMode.siteReview,
          label: Text(context.l10n.bookSourcesDedupeModeSite),
        ),
      ],
      selected: {mode},
      onSelectionChanged: onChanged == null
          ? null
          : (selection) => onChanged!(selection.first),
    );
  }
}

typedef _DedupeRow = ({
  BookSourceDedupeGroup group,
  BookSourceDedupeCandidate? candidate,
});

// Flatten data, not widgets: even one group containing thousands of variants
// only builds rows that are visible in the scroll viewport.
List<_DedupeRow> _reviewRows(
  List<BookSourceDedupeGroup> groups, {
  bool installed = false,
}) => [
  for (final group in groups) ...[
    (group: group, candidate: null),
    for (final candidate in group.candidates)
      if (!installed || candidate.index != group.recommendedIndex)
        (group: group, candidate: candidate),
  ],
];

class _DedupeGroupHeader extends StatelessWidget {
  const _DedupeGroupHeader({required this.group, this.winner});
  final BookSourceDedupeGroup group;
  final RegisteredBookSource? winner;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _reason(context, group.confidence),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          winner == null
              ? group.key
              : '${context.l10n.bookSourcesDedupeRecommended}: ${winner!.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (winner != null &&
            group.candidates.any(
              (candidate) =>
                  candidate.index == group.recommendedIndex &&
                  candidate.isReferenced,
            ))
          Text(
            context.l10n.bookSourcesMaintenanceShelfProtected,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 12,
            ),
          ),
      ],
    ),
  );
}

class _CandidateSubtitle extends StatelessWidget {
  const _CandidateSubtitle({required this.url, required this.recommended});

  final String url;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    return Text(
      recommended ? '${context.l10n.bookSourcesDedupeRecommended} - $url' : url,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

String _reason(BuildContext context, BookSourceDedupeConfidence confidence) =>
    switch (confidence) {
      BookSourceDedupeConfidence.exact =>
        context.l10n.bookSourcesDedupeExactReason,
      BookSourceDedupeConfidence.canonical =>
        context.l10n.bookSourcesDedupeCanonicalReason,
      BookSourceDedupeConfidence.sameSite =>
        context.l10n.bookSourcesDedupeSiteReason,
      BookSourceDedupeConfidence.conflict =>
        context.l10n.bookSourcesDedupeSiteReason,
    };

SourceImportPreview _changeImportMode(
  ({SourceImportPreview preview, BookSourceDedupeMode mode}) request,
) => request.preview.withMode(request.mode);

BookSourceDedupeResult _changeInstalledMode(
  ({List<BookSourceDedupeCandidate> candidates, BookSourceDedupeMode mode})
  request,
) => const BookSourceDedupeEngine().analyze(
  request.candidates,
  mode: request.mode,
);
