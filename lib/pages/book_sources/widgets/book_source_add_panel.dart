import 'package:flutter/material.dart';

import '../../../book_sources/services/book_source_import_analyzer.dart';
import '../../../utils/localization_extension.dart';

enum BookSourceAddMode { link, file }

class BookSourceAddPanel extends StatelessWidget {
  const BookSourceAddPanel({
    super.key,
    required this.controller,
    required this.connecting,
    required this.responsibilityAccepted,
    required this.mode,
    required this.analysis,
    required this.errorText,
    required this.sheet,
    required this.onModeChanged,
    required this.onResponsibilityChanged,
    required this.onCancel,
    required this.onAnalyzeLink,
    required this.onChooseFile,
    required this.onAdd,
  });

  final TextEditingController controller;
  final bool connecting;
  final bool responsibilityAccepted;
  final BookSourceAddMode mode;
  final BookSourceImportAnalysis? analysis;
  final String? errorText;
  final bool sheet;
  final ValueChanged<BookSourceAddMode> onModeChanged;
  final ValueChanged<bool> onResponsibilityChanged;
  final VoidCallback onCancel;
  final VoidCallback onAnalyzeLink;
  final VoidCallback onChooseFile;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, sheet ? 4 : 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.bookSourcesAdd,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<BookSourceAddMode>(
              key: const Key('bookSourceAddMode'),
              segments: [
                ButtonSegment(
                  value: BookSourceAddMode.link,
                  icon: const Icon(Icons.link_rounded),
                  label: Text(context.l10n.bookSourcesImportLink),
                ),
                ButtonSegment(
                  value: BookSourceAddMode.file,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(context.l10n.additionalSourcesChooseFile),
                ),
              ],
              selected: {mode},
              onSelectionChanged: connecting
                  ? null
                  : (selection) => onModeChanged(selection.first),
            ),
            const SizedBox(height: 20),
            if (mode == BookSourceAddMode.link)
              TextField(
                key: const Key('bookSourceUnifiedUrlField'),
                controller: controller,
                enabled: !connecting,
                autofocus: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.l10n.bookSourcesUrlLabel,
                  hintText: context.l10n.bookSourcesUrlHint,
                  prefixIcon: const Icon(Icons.link_rounded),
                  border: const OutlineInputBorder(),
                ),
              )
            else
              OutlinedButton.icon(
                key: const Key('bookSourceChooseJsonButton'),
                onPressed: connecting ? null : onChooseFile,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(context.l10n.additionalSourcesChooseFile),
              ),
            if (analysis case final detected?) ...[
              const SizedBox(height: 14),
              _DetectedSourceSummary(analysis: detected),
            ],
            if (errorText != null) ...[
              const SizedBox(height: 10),
              Text(errorText!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, size: 21, color: scheme.primary),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      context.l10n.bookSourcesNoOfficialSourcesNotice,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('bookSourceResponsibilityCheckbox'),
              value: responsibilityAccepted,
              enabled: !connecting,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                context.l10n.bookSourcesResponsibilityAck,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              onChanged: connecting
                  ? null
                  : (value) => onResponsibilityChanged(value ?? false),
            ),
            if (connecting) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(context.l10n.bookSourcesConnecting),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: connecting ? null : onCancel,
                    child: Text(context.l10n.bookSourcesCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('bookSourceConnectButton'),
                    onPressed: connecting || !responsibilityAccepted
                        ? null
                        : analysis == null
                        ? mode == BookSourceAddMode.link
                              ? onAnalyzeLink
                              : null
                        : onAdd,
                    child: Text(
                      analysis == null
                          ? context.l10n.bookSourcesAnalyze
                          : context.l10n.bookSourcesConfirm,
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

class _DetectedSourceSummary extends StatelessWidget {
  const _DetectedSourceSummary({required this.analysis});

  final BookSourceImportAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = analysis.additionalPreview;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            analysis.kind == BookSourceImportKind.orsp
                ? context.l10n.bookSourcesDetectedOrsp
                : context.l10n.bookSourcesDetectedAdditional,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          if (analysis.kind == BookSourceImportKind.orsp)
            Text(analysis.sources.single.name)
          else if (preview != null)
            Text(
              context.l10n.additionalSourcesQuickPreview(
                preview.sources.length,
                preview.skipped,
              ),
            ),
        ],
      ),
    );
  }
}
