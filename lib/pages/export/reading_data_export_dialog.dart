import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/export/reading_data_export.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/side_toast.dart';

typedef ReadingDataExportServiceFactory = ReadingDataExportService Function();

Future<void> showReadingDataExportDialog(
  BuildContext context, {
  required Book book,
  ReadingDataExportServiceFactory? serviceFactory,
}) async {
  final service =
      serviceFactory?.call() ??
      ReadingDataExportService(
        overwriteConfirmation: (path) => _confirmOverwrite(context, path),
      );
  ReadingDataExportDocument document;
  try {
    document = await service.prepareDocument(book, labels: _labels(context));
  } catch (_) {
    if (context.mounted) {
      showSideToast(
        context,
        context.l10n.readingDataExportFailed,
        kind: SideToastKind.error,
      );
    }
    return;
  }
  if (!context.mounted) return;
  if (document.totalCount == 0) {
    showSideToast(
      context,
      context.l10n.readingDataExportEmpty,
      kind: SideToastKind.warning,
    );
    return;
  }

  final shouldExport = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.readingDataExportAction),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryRow(
              icon: Icons.menu_book_outlined,
              title: context.l10n.readingDataExportWholeBook,
              body: book.title,
            ),
            const SizedBox(height: 14),
            _SummaryRow(
              icon: Icons.edit_note_rounded,
              title: context.l10n.readingDataExportCounts(
                document.highlightCount,
                document.underlineCount,
                document.noteCount,
              ),
              body: context.l10n.readingDataExportWholeBookHint,
            ),
            const SizedBox(height: 14),
            _SummaryRow(
              icon: Icons.privacy_tip_outlined,
              title: context.l10n.readingDataExportSubtitle,
              body: context.l10n.readingDataExportPrivacySummary,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton.icon(
          key: const ValueKey('reading-data-export-confirm-button'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.file_download_outlined),
          label: Text(
            context.l10n.readingDataExportButton(document.totalCount),
          ),
        ),
      ],
    ),
  );
  if (shouldExport != true || !context.mounted) return;

  showSideToast(context, context.l10n.readingDataExportPreparing);
  final result = await service.export(document);
  if (!context.mounted) return;
  switch (result.status) {
    case ReadingDataExportStatus.success:
      showSideToast(
        context,
        context.l10n.readingDataExportSuccess(
          result.location ?? result.displayName ?? document.suggestedFileName,
        ),
        kind: SideToastKind.success,
      );
    case ReadingDataExportStatus.cancelled:
      break;
    case ReadingDataExportStatus.unsupported:
      showSideToast(
        context,
        context.l10n.readingDataExportUnsupported,
        kind: SideToastKind.warning,
      );
    case ReadingDataExportStatus.failure:
      showSideToast(
        context,
        context.l10n.readingDataExportFailed,
        kind: SideToastKind.error,
      );
  }
}

Future<bool> _confirmOverwrite(BuildContext context, String path) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.readingDataExportReplaceTitle),
          content: Text(context.l10n.readingDataExportReplaceMessage(path)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(context.l10n.readingDataExportReplaceAction),
            ),
          ],
        ),
      ) ??
      false;
}

ReadingDataExportLabels _labels(BuildContext context) {
  final l10n = context.l10n;
  return ReadingDataExportLabels(
    author: l10n.readingDataExportAuthor,
    wholeBook: l10n.readingDataExportWholeBook,
    contents: l10n.readingDataExportContents,
    exportedAt: l10n.readingDataExportExportedAt,
    myNote: l10n.readingDataExportMyNote,
    highlight: l10n.noteTypeHighlight,
    underline: l10n.noteTypeUnderline,
    note: l10n.noteTypeNote,
    unknownChapter: l10n.readingDataExportUnknownChapter,
    pageLabel: l10n.readingDataExportPositionPage,
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: colors.onSecondaryContainer),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.42,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
