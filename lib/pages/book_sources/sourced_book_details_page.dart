import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_gateway.dart';
import '../../book_sources/services/book_source_shelf_service.dart';
import '../../services/library/download_task_controller.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../../widgets/side_toast.dart';
import 'models/sourced_book.dart';
import 'widgets/book_source_text_normalizer.dart';
import 'widgets/sourced_book_cards.dart';
import 'widgets/sourced_book_details_controller.dart';
import 'widgets/sourced_book_details_sheet.dart';

/// Keeps book information and actions available across shelf and reader flows.
class SourcedBookDetailsPage extends StatelessWidget {
  const SourcedBookDetailsPage({
    super.key,
    required this.result,
    required this.gateway,
    required this.shelfService,
    required this.onRead,
    required this.onDownloadContinuesInBackground,
  });

  final SourcedBook result;
  final BookSourceGateway gateway;
  final BookSourceShelfService shelfService;
  final Future<void> Function(BuildContext context, BookSourceBook book) onRead;
  final VoidCallback onDownloadContinuesInBackground;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
    create: (_) =>
        SourcedBookDetailsController(
            initialResult: result,
            gateway: gateway,
            shelf: BookSourceShelfPortAdapter(shelfService),
            downloads: DownloadTaskPortAdapter(
              context.read<DownloadTaskController>(),
              shelfService,
            ),
          )
          ..loadDetails()
          ..loadShelfStatus(),
    child: _DetailsPageContent(
      onRead: onRead,
      onDownloadContinuesInBackground: onDownloadContinuesInBackground,
    ),
  );
}

class _DetailsPageContent extends StatelessWidget {
  const _DetailsPageContent({
    required this.onRead,
    required this.onDownloadContinuesInBackground,
  });

  final Future<void> Function(BuildContext context, BookSourceBook book) onRead;
  final VoidCallback onDownloadContinuesInBackground;

  Future<void> _read(
    BuildContext context,
    SourcedBookDetailsController controller,
  ) async {
    if (controller.state.step == SourcedBookDetailsStep.openingReader) return;
    controller.showDetails();
    final book = controller.beginOpeningReader();
    if (book == null) return;
    try {
      await onRead(context, book);
    } catch (_) {
      if (context.mounted) {
        showSideToast(context, context.l10n.bookSourceDetailsReadFailed);
      }
    } finally {
      if (context.mounted) {
        controller.showDetails();
        await controller.loadShelfStatus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SourcedBookDetailsController>();
    final state = controller.state;
    final book = state.result.book;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final description = normalizeBookSourceDescription(book.description);
    final busy =
        state.step == SourcedBookDetailsStep.submitting ||
        state.step == SourcedBookDetailsStep.openingReader;
    final downloading =
        state.downloadTask?.state == DownloadTaskState.queued ||
        state.downloadTask?.state == DownloadTaskState.downloading;

    return FloatingSubpageScaffold(
      key: const Key('bookSourceDetailsPage'),
      title: context.l10n.bookSourceDetailsTitle,
      maxHeaderWidth: 800,
      body: SingleChildScrollView(
        key: const Key('bookSourceDetailsScroll'),
        padding: floatingSubpagePadding(context, left: 24, right: 24, top: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 752),
            child: Column(
              key: const Key('bookSourceDetailsContent'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _BookIdentity(result: state.result),
                const SizedBox(height: 28),
                if (state.isLoadingDetails) ...[
                  LinearProgressIndicator(
                    key: const Key('bookSourceDetailsLoading'),
                    semanticsLabel: context.l10n.loading,
                    minHeight: 2,
                  ),
                  const SizedBox(height: 20),
                ],
                if (state.detailError != null) ...[
                  _RetryMessage(
                    message: context.l10n.bookSourceDetailsLoadFailed,
                    onRetry: controller.loadDetails,
                    retryKey: const Key('bookSourceDetailsRetryButton'),
                  ),
                  const SizedBox(height: 20),
                ],
                Text(
                  context.l10n.bookSourceDetailsDescription,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  description.isEmpty
                      ? context.l10n.bookSourceDetailsNoDescription
                      : description,
                  style: textTheme.bodyLarge?.copyWith(
                    height: 1.75,
                    color: description.isEmpty
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
                if (book.latestChapter?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 28),
                  Text(
                    context.l10n.bookSourceDetailsLatestChapter,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(book.latestChapter!, style: textTheme.bodyLarge),
                  if (book.updatedAt != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      MaterialLocalizations.of(
                        context,
                      ).formatMediumDate(book.updatedAt!.toLocal()),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 28),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ListTile(
                  key: const Key('bookSourceDownloadLocalOption'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download_for_offline_outlined),
                  title: Text(context.l10n.bookSourceDownloadLocal),
                  subtitle: Text(context.l10n.bookSourceDownloadLocalHint),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  enabled: !busy && !downloading,
                  onTap: controller.startDownload,
                ),
                if (state.downloadTask != null)
                  SourcedBookDownloadView(
                    task: state.downloadTask,
                    onCancel: controller.cancelDownload,
                    onBackground: () {
                      Navigator.of(context).pop();
                      onDownloadContinuesInBackground();
                    },
                    onRetry: controller.startDownload,
                    onBack: controller.dismissDownload,
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: Material(
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 752),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.step == SourcedBookDetailsStep.addFailed)
                      _RetryMessage(
                        key: const Key('bookSourceAddFailed'),
                        message: context.l10n.bookSourceDetailsAddFailed,
                        onRetry: controller.addOnline,
                        retryKey: const Key('bookSourceAddRetryButton'),
                      ),
                    if (state.step == SourcedBookDetailsStep.submitting) ...[
                      LinearProgressIndicator(
                        semanticsLabel: context.l10n.bookSourceAddToShelf,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Builder(
                      builder: (context) {
                        final shelf = OutlinedButton.icon(
                          key: const Key('bookSourceAddToShelfButton'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                          ),
                          onPressed:
                              busy ||
                                  downloading ||
                                  state.checkingShelf ||
                                  state.hasShelfBook
                              ? null
                              : controller.addOnline,
                          icon: Icon(
                            state.hasShelfBook
                                ? Icons.check_rounded
                                : Icons.add_to_photos_outlined,
                          ),
                          label: Text(
                            state.hasShelfBook
                                ? context.l10n.bookSourceDetailsOnShelf
                                : context.l10n.bookSourceAddToShelf,
                            key: state.hasShelfBook
                                ? const Key('bookSourceOnShelf')
                                : null,
                            textAlign: TextAlign.center,
                          ),
                        );
                        final read = FilledButton.icon(
                          key: const Key('bookSourceReadButton'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                          ),
                          onPressed: busy || downloading
                              ? null
                              : () => _read(context, controller),
                          icon: const Icon(Icons.menu_book_rounded),
                          label: Text(
                            context.l10n.reading,
                            textAlign: TextAlign.center,
                          ),
                        );
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: shelf),
                              const SizedBox(width: 12),
                              Expanded(child: read),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookIdentity extends StatelessWidget {
  const _BookIdentity({required this.result});

  final SourcedBook result;

  @override
  Widget build(BuildContext context) {
    final book = result.book;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final tags = {
      if (book.status?.trim().isNotEmpty ?? false) book.status!,
      ...book.categories.where((value) => value.trim().isNotEmpty),
    };
    final metadata = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          book.title,
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
        if (book.author.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(book.author, style: textTheme.bodyLarge),
        ],
        const SizedBox(height: 8),
        Text(
          result.source.name,
          style: textTheme.bodyMedium?.copyWith(color: scheme.primary),
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags
                .map(
                  (tag) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tag,
                      style: textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SourcedBookCoverThumb(
        book: book,
        width: 112,
        height: 160,
        radius: 8,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 320 ||
            MediaQuery.textScalerOf(context).scale(14) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: cover),
              const SizedBox(height: 24),
              metadata,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: 24),
            Expanded(child: metadata),
          ],
        );
      },
    );
  }
}

class _RetryMessage extends StatelessWidget {
  const _RetryMessage({
    super.key,
    required this.message,
    required this.onRetry,
    required this.retryKey,
  });

  final String message;
  final VoidCallback onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton.icon(
          key: retryKey,
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(context.l10n.retry),
        ),
      ],
    ),
  );
}
