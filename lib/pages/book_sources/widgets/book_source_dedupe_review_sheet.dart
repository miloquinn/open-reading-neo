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
  });

  final BookSourceDedupeMode mode;
  final Set<int> selectedIndices;
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
  late Set<int> _selected = _preview.selectedIndices.toSet();

  void _setMode(BookSourceDedupeMode mode) {
    setState(() {
      _preview = _preview.withMode(mode);
      _selected = _preview.selectedIndices.toSet();
    });
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
          _ModeSelector(mode: _preview.mode, onChanged: _setMode),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() {
              _selected = _preview.dedupeResult.defaultSelectedIndices.toSet();
            }),
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(context.l10n.bookSourcesDedupeRestoreDefaults),
          ),
        ],
      ),
      groups: _preview.dedupeResult.groups
          .map((group) {
            return _ImportGroup(
              group: group,
              selected: _selected,
              onSelected: (index, selected) => setState(() {
                final indices = group.candidates
                    .map((item) => item.index)
                    .toSet();
                if (group.requiresReview) {
                  selected ? _selected.add(index) : _selected.remove(index);
                } else {
                  _selected.removeAll(indices);
                  _selected.add(index);
                }
              }),
            );
          })
          .toList(growable: false),
      actionLabel: context.l10n.bookSourcesConfirm,
      onConfirm: () => Navigator.pop(
        context,
        BookSourceImportDedupeSelection(
          mode: _preview.mode,
          selectedIndices: Set.unmodifiable(_selected),
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
  late Set<String> _selected = _defaultSelection(_result);

  Set<String> _defaultSelection(BookSourceDedupeResult result) => {
    for (final group in result.groups)
      if (!group.requiresReview)
        for (final candidate in group.candidates)
          if (candidate.index != group.recommendedIndex &&
              widget.sourcesByIndex[candidate.index]!.enabled)
            widget.sourcesByIndex[candidate.index]!.id,
  };

  void _setMode(BookSourceDedupeMode mode) {
    setState(() {
      _result = const BookSourceDedupeEngine().analyze(
        widget.result.candidates,
        mode: mode,
      );
      _selected = _defaultSelection(_result);
    });
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
          _ModeSelector(mode: _result.mode, onChanged: _setMode),
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
      groups: _result.groups
          .map((group) {
            final winner = widget.sourcesByIndex[group.recommendedIndex]!;
            final candidates = group.candidates
                .where((candidate) => candidate.index != group.recommendedIndex)
                .map((candidate) => widget.sourcesByIndex[candidate.index]!)
                .toList(growable: false);
            return _InstalledGroup(
              group: group,
              winner: winner,
              candidates: candidates,
              selected: _selected,
              onChanged: (id, selected) => setState(() {
                selected ? _selected.add(id) : _selected.remove(id);
              }),
            );
          })
          .toList(growable: false),
      actionLabel: context.l10n.bookSourcesDedupeDisableSelected(
        _selected.length,
      ),
      onConfirm: _selected.isEmpty
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
    required this.groups,
    required this.actionLabel,
    required this.onConfirm,
  });

  final String title;
  final String summary;
  final Widget header;
  final List<Widget> groups;
  final String actionLabel;
  final VoidCallback? onConfirm;

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
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: groups.isEmpty
                ? Center(child: Text(context.l10n.bookSourcesDedupeNone))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: groups.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) => groups[index],
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
  final ValueChanged<BookSourceDedupeMode> onChanged;

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
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _ImportGroup extends StatelessWidget {
  const _ImportGroup({
    required this.group,
    required this.selected,
    required this.onSelected,
  });

  final BookSourceDedupeGroup group;
  final Set<int> selected;
  final void Function(int index, bool selected) onSelected;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(_reason(context, group.confidence)),
      subtitle: Text(group.key, maxLines: 1, overflow: TextOverflow.ellipsis),
      children: group.candidates
          .map((candidate) {
            final isRecommended = candidate.index == group.recommendedIndex;
            final title = candidate.name.isEmpty
                ? candidate.identity.raw
                : candidate.name;
            if (group.requiresReview) {
              return CheckboxListTile(
                value: selected.contains(candidate.index),
                onChanged: (value) =>
                    onSelected(candidate.index, value ?? false),
                title: Text(title),
                subtitle: _CandidateSubtitle(
                  url: candidate.identity.raw,
                  recommended: isRecommended,
                ),
              );
            }
            return RadioGroup<int>(
              groupValue: selected
                  .intersection(
                    group.candidates.map((item) => item.index).toSet(),
                  )
                  .firstOrNull,
              onChanged: (value) {
                if (value != null) onSelected(value, true);
              },
              child: RadioListTile<int>(
                value: candidate.index,
                title: Text(title),
                subtitle: _CandidateSubtitle(
                  url: candidate.identity.raw,
                  recommended: isRecommended,
                ),
              ),
            );
          })
          .toList(growable: false),
    );
  }
}

class _InstalledGroup extends StatelessWidget {
  const _InstalledGroup({
    required this.group,
    required this.winner,
    required this.candidates,
    required this.selected,
    required this.onChanged,
  });

  final BookSourceDedupeGroup group;
  final RegisteredBookSource winner;
  final List<RegisteredBookSource> candidates;
  final Set<String> selected;
  final void Function(String id, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(_reason(context, group.confidence)),
      subtitle: Text(
        '${context.l10n.bookSourcesDedupeRecommended}: ${winner.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: candidates
          .map((source) {
            return CheckboxListTile(
              value: selected.contains(source.id),
              onChanged: (value) => onChanged(source.id, value ?? false),
              title: Text(source.name),
              subtitle: Text(
                '${source.sourceConfig?['bookSourceUrl'] ?? source.apiBaseUrl}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          })
          .toList(growable: false),
    );
  }
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
