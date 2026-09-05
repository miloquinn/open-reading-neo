import 'package:flutter/material.dart';

import '../../../book_sources/services/book_source_import_analyzer.dart';
import '../../../utils/localization_extension.dart';
import '../controllers/book_source_add_controller.dart';
import 'book_source_pill.dart';

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
    required this.onReviewDedupe,
    this.phase = BookSourceAddPhase.idle,
    this.pickingFile = false,
    this.fileName,
    this.errorSummary,
    this.importUnavailableReason,
  });

  final TextEditingController controller;
  final bool connecting;
  final bool responsibilityAccepted;
  final BookSourceAddMode mode;
  final BookSourceImportAnalysis? analysis;
  final String? errorText;
  final bool sheet;
  final BookSourceAddPhase phase;
  final bool pickingFile;
  final String? fileName;
  final String? errorSummary;
  final String? importUnavailableReason;
  final ValueChanged<BookSourceAddMode> onModeChanged;
  final ValueChanged<bool> onResponsibilityChanged;
  final VoidCallback onCancel;
  final VoidCallback onAnalyzeLink;
  final VoidCallback onChooseFile;
  final VoidCallback onAdd;
  final VoidCallback onReviewDedupe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = connecting || pickingFile;
    final saving = phase == BookSourceAddPhase.saving;
    final detected = analysis;
    final count = detected == null
        ? 0
        : detected.additionalPreview?.selectedIndices.length ??
              detected.sources.length;
    final canImport = count > 0 && importUnavailableReason == null;
    final action = detected != null
        ? onAdd
        : mode == BookSourceAddMode.link
        ? onAnalyzeLink
        : onChooseFile;

    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.bookSourcesAdd,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  key: const Key('bookSourceImportCloseButton'),
                  tooltip: context.l10n.bookSourcesCancel,
                  onPressed: saving ? null : onCancel,
                  icon: const Icon(Icons.close_rounded, size: 21),
                  style: IconButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const Key('bookSourceImportScroll'),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    key: const Key('bookSourceAddMode'),
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final value in BookSourceAddMode.values)
                        BookSourcePill(
                          label: value == BookSourceAddMode.link
                              ? context.l10n.bookSourcesImportLink
                              : context.l10n.bookSourcesImportFileTab,
                          icon: value == BookSourceAddMode.link
                              ? Icons.link_rounded
                              : Icons.description_outlined,
                          selected: mode == value,
                          onPressed: busy ? null : () => onModeChanged(value),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          backgroundColor: scheme.surfaceContainerLow,
                          foregroundColor: scheme.onSurfaceVariant,
                          selectedBackgroundColor: scheme.primary.withValues(
                            alpha: 0.1,
                          ),
                          selectedForegroundColor: scheme.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (mode == BookSourceAddMode.link)
                    TextField(
                      key: const Key('bookSourceUnifiedUrlField'),
                      controller: controller,
                      enabled: !busy,
                      autofocus: false,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!busy &&
                            responsibilityAccepted &&
                            detected == null) {
                          onAnalyzeLink();
                        }
                      },
                      decoration: InputDecoration(
                        hintText: context.l10n.bookSourcesUrlHint,
                        labelText: context.l10n.bookSourcesUrlLabel,
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                      ),
                    )
                  else
                    InkWell(
                      key: const Key('bookSourceChooseJsonButton'),
                      onTap: busy ? null : onChooseFile,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              color: scheme.primary,
                              size: 25,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    fileName ??
                                        context
                                            .l10n
                                            .additionalSourcesChooseFile,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    context.l10n.bookSourcesImportFileHint,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: scheme.onSurfaceVariant,
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (detected != null) ...[
                    const SizedBox(height: 20),
                    Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    Padding(
                      key: const Key('bookSourceImportPreview'),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: _DetectedSourceSummary(
                        analysis: detected,
                        onReviewDedupe: busy ? null : onReviewDedupe,
                      ),
                    ),
                    if (importUnavailableReason != null)
                      Text(
                        importUnavailableReason!,
                        style: TextStyle(color: scheme.error, height: 1.4),
                      ),
                    if (count == 0)
                      Text(
                        context.l10n.bookSourcesImportEmpty,
                        style: TextStyle(color: scheme.error),
                      ),
                  ],
                  if (errorText != null) ...[
                    const SizedBox(height: 16),
                    Column(
                      key: const Key('bookSourceImportError'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          errorSummary ??
                              (detected == null
                                  ? context.l10n.bookSourcesImportFailed
                                  : context.l10n.bookSourcesImportSaveFailed),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                            height: 1.5,
                          ),
                        ),
                        ExpansionTile(
                          dense: true,
                          tilePadding: EdgeInsets.zero,
                          shape: const Border(),
                          collapsedShape: const Border(),
                          title: Text(
                            context.l10n.bookSourcesImportErrorDetails,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: SelectableText(
                                errorText!,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  ExpansionTile(
                    key: const Key('bookSourceImportUsageNotice'),
                    dense: true,
                    tilePadding: EdgeInsets.zero,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(
                      context.l10n.bookSourcesImportUsageNotice,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          context.l10n.bookSourcesNoOfficialSourcesNotice,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    key: const Key('bookSourceResponsibilityCheckbox'),
                    value: responsibilityAccepted,
                    enabled: !busy,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      context.l10n.bookSourcesResponsibilityAck,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    onChanged: busy
                        ? null
                        : (value) => onResponsibilityChanged(value ?? false),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (busy) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        pickingFile
                            ? context.l10n.bookSourcesImportPicking
                            : switch (phase) {
                                BookSourceAddPhase.downloading =>
                                  context.l10n.bookSourcesImportDownloading,
                                BookSourceAddPhase.analyzing =>
                                  context.l10n.bookSourcesImportAnalyzing,
                                BookSourceAddPhase.saving =>
                                  context.l10n.bookSourcesImportSaving,
                                BookSourceAddPhase.idle =>
                                  context.l10n.bookSourcesConnecting,
                              },
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(
                      key: Key('bookSourceImportProgress'),
                      minHeight: 2,
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton(
                    key: const Key('bookSourceConnectButton'),
                    onPressed:
                        busy ||
                            !responsibilityAccepted ||
                            (detected != null && !canImport)
                        ? null
                        : action,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    child: Text(
                      errorText != null
                          ? context.l10n.bookSourcesImportRetry
                          : detected != null
                          ? context.l10n.bookSourcesImportAction(count)
                          : mode == BookSourceAddMode.file
                          ? context.l10n.additionalSourcesChooseFile
                          : context.l10n.bookSourcesAnalyze,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetectedSourceSummary extends StatelessWidget {
  const _DetectedSourceSummary({
    required this.analysis,
    required this.onReviewDedupe,
  });
  final BookSourceImportAnalysis analysis;
  final VoidCallback? onReviewDedupe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = analysis.additionalPreview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          preview == null
              ? analysis.sources.single.name
              : context.l10n.bookSourcesDedupeImportSummary(
                  preview.selectedIndices.length,
                  preview.duplicates,
                  preview.errors.length,
                ),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          preview == null
              ? context.l10n.bookSourcesDetectedOrsp
              : context.l10n.bookSourcesImportTypeSummary(
                  preview.runnableTextSources,
                  preview.runnableImageSources,
                  preview.unsupported,
                ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        if (preview != null && preview.dedupeResult.groups.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('bookSourceReviewDedupeButton'),
            onPressed: onReviewDedupe,
            icon: const Icon(Icons.difference_outlined, size: 18),
            label: Text(context.l10n.bookSourcesDedupeReviewAction),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      ],
    );
  }
}
