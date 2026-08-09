import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_gateway.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/services/library/download_task_controller.dart';
import 'package:xxread/utils/localization_extension.dart';

import 'book_source_text_normalizer.dart';
import '../models/sourced_book.dart';
import 'sourced_book_cards.dart';
import 'sourced_book_details_controller.dart';

class SourcedBookDetailsLoader extends StatelessWidget {
  const SourcedBookDetailsLoader({
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
  final Future<void> Function(BookSourceBook book) onRead;
  final VoidCallback onDownloadContinuesInBackground;

  @override
  Widget build(BuildContext context) {
    final downloads = context.read<DownloadTaskController>();
    return ChangeNotifierProvider(
      create: (_) => SourcedBookDetailsController(
        initialResult: result,
        gateway: gateway,
        shelf: BookSourceShelfPortAdapter(shelfService),
        downloads: DownloadTaskPortAdapter(downloads, shelfService),
      )..loadDetails(),
      child: Consumer<SourcedBookDetailsController>(
        builder: (_, controller, _) => SourcedBookDetailsSheet(
          key: ValueKey(controller.state.result.book.id),
          onRead: onRead,
          onDownloadContinuesInBackground: onDownloadContinuesInBackground,
        ),
      ),
    );
  }
}

class SourcedBookDetailsSheet extends StatefulWidget {
  const SourcedBookDetailsSheet({
    super.key,
    required this.onRead,
    required this.onDownloadContinuesInBackground,
  });

  final Future<void> Function(BookSourceBook book) onRead;
  final VoidCallback onDownloadContinuesInBackground;

  @override
  State<SourcedBookDetailsSheet> createState() =>
      _SourcedBookDetailsSheetState();
}

class _SourcedBookDetailsSheetState extends State<SourcedBookDetailsSheet> {
  bool _closingScheduled = false;
  bool _closing = false;

  Future<void> _openReader(SourcedBookDetailsController controller) async {
    final book = controller.beginOpeningReader();
    if (book == null) return;
    _closing = true;
    Navigator.of(context).pop();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await widget.onRead(book);
  }

  Future<void> _addOnline(SourcedBookDetailsController controller) async {
    if (await controller.addOnline() && mounted) _scheduleClose();
  }

  void _scheduleClose() {
    if (_closingScheduled) return;
    _closingScheduled = true;
    _closing = true;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 550), () {
        if (mounted) Navigator.of(context).pop();
      }),
    );
  }

  void _continueDownloadInBackground() {
    _closing = true;
    Navigator.of(context).pop();
    widget.onDownloadContinuesInBackground();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SourcedBookDetailsController>();
    final state = controller.state;
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations;
    final book = state.result.book;
    final authorAndSource = [
      book.author,
      state.result.source.name,
    ].where((item) => item.isNotEmpty).join(' · ');
    if (!_closing && state.downloadTask?.state == DownloadTaskState.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleClose();
      });
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              book.title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              authorAndSource,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: AnimatedSize(
                key: const Key('bookSourceSheetAnimatedSize'),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 260),
                reverseDuration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                clipBehavior: Clip.hardEdge,
                child: AnimatedSwitcher(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  reverseDuration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) =>
                      currentChild ?? const SizedBox.shrink(),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: reduceMotion
                            ? Offset.zero
                            : const Offset(0, 0.035),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(state.step),
                    child: _buildStep(context, controller, state, reduceMotion),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(
    BuildContext context,
    SourcedBookDetailsController controller,
    SourcedBookDetailsState state,
    bool reduceMotion,
  ) => switch (state.step) {
    SourcedBookDetailsStep.details => _DetailsView(
      book: state.result.book,
      onShelf: controller.showShelfOptions,
      onRead: () => _openReader(controller),
    ),
    SourcedBookDetailsStep.shelfOptions => _ShelfOptionsView(
      onAddOnline: () => _addOnline(controller),
      onDownload: controller.startDownload,
      onBack: controller.showDetails,
    ),
    SourcedBookDetailsStep.openingReader => _SubmittingView(
      viewKey: const Key('bookSourceReaderOpening'),
      message: context.l10n.reading,
    ),
    SourcedBookDetailsStep.submitting => _SubmittingView(
      viewKey: const Key('bookSourceActionSubmitting'),
      message: context.l10n.bookSourceAddToShelf,
    ),
    SourcedBookDetailsStep.added => SourcedBookShelfCompletionView(
      book: state.result.book,
      reduceMotion: reduceMotion,
      message: context.l10n.bookSourceAddedOnline,
    ),
    SourcedBookDetailsStep.alreadyAdded => SourcedBookShelfCompletionView(
      book: state.result.book,
      reduceMotion: true,
      alreadyAdded: true,
      message: context.l10n.bookSourceAlreadyOnShelf,
    ),
    SourcedBookDetailsStep.addFailed => _AddFailedView(
      error: state.addError,
      onCancel: controller.showShelfOptions,
      onRetry: () => _addOnline(controller),
    ),
    SourcedBookDetailsStep.downloading => _DownloadView(
      task: state.downloadTask,
      onCancel: controller.cancelDownload,
      onBackground: _continueDownloadInBackground,
      onRetry: controller.startDownload,
      onBack: controller.showShelfOptions,
    ),
  };
}

class _DetailsView extends StatelessWidget {
  const _DetailsView({
    required this.book,
    required this.onShelf,
    required this.onRead,
  });

  final BookSourceBook book;
  final VoidCallback onShelf;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final description = normalizeBookSourceDescription(book.description);
    return Column(
      key: const Key('bookSourceDetailsContent'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            key: const Key('bookSourceDetailsScroll'),
            padding: const EdgeInsets.only(bottom: 4),
            child: description.isEmpty
                ? const SizedBox.shrink()
                : Text(description, style: const TextStyle(height: 1.5)),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  key: const Key('bookSourceAddToShelfButton'),
                  onPressed: onShelf,
                  icon: const Icon(Icons.add_to_photos_outlined),
                  label: Text(context.l10n.bookSourceAddToShelf),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  key: const Key('bookSourceReadButton'),
                  onPressed: onRead,
                  icon: const Icon(Icons.menu_book_rounded),
                  label: Text(context.l10n.reading),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShelfOptionsView extends StatelessWidget {
  const _ShelfOptionsView({
    required this.onAddOnline,
    required this.onDownload,
    required this.onBack,
  });

  final VoidCallback onAddOnline;
  final VoidCallback onDownload;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('bookSourceShelfOptions'),
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(
        key: const Key('bookSourceAddOnlineOption'),
        leading: const Icon(Icons.cloud_outlined),
        title: Text(context.l10n.bookSourceAddOnline),
        subtitle: Text(context.l10n.bookSourceAddOnlineHint),
        onTap: onAddOnline,
      ),
      ListTile(
        key: const Key('bookSourceDownloadLocalOption'),
        leading: const Icon(Icons.download_for_offline_outlined),
        title: Text(context.l10n.bookSourceDownloadLocal),
        subtitle: Text(context.l10n.bookSourceDownloadLocalHint),
        onTap: onDownload,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
          label: Text(context.l10n.back),
        ),
      ),
    ],
  );
}

class _SubmittingView extends StatelessWidget {
  const _SubmittingView({required this.viewKey, required this.message});

  final Key viewKey;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    key: viewKey,
    padding: const EdgeInsets.symmetric(vertical: 34),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(height: 16),
        Text(message),
      ],
    ),
  );
}

class _AddFailedView extends StatelessWidget {
  const _AddFailedView({
    required this.error,
    required this.onCancel,
    required this.onRetry,
  });

  final Object? error;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('bookSourceAddFailed'),
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 38,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 12),
        Text(
          '$error',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(onPressed: onCancel, child: Text(context.l10n.cancel)),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('bookSourceAddRetryButton'),
              onPressed: onRetry,
              child: Text(context.l10n.retry),
            ),
          ],
        ),
      ],
    ),
  );
}

class _DownloadView extends StatelessWidget {
  const _DownloadView({
    required this.task,
    required this.onCancel,
    required this.onBackground,
    required this.onRetry,
    required this.onBack,
  });

  final BookDownloadTask? task;
  final VoidCallback onCancel;
  final VoidCallback onBackground;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final state = task?.state;
    final status = switch (state) {
      DownloadTaskState.queued => context.l10n.downloadTaskQueued,
      DownloadTaskState.downloading => context.l10n.downloadTaskDownloading,
      DownloadTaskState.completed => context.l10n.bookSourceDownloadComplete,
      DownloadTaskState.failed => context.l10n.bookSourceDownloadFailed(
        '${task?.error ?? ''}',
      ),
      DownloadTaskState.cancelled => context.l10n.downloadTaskCancelled,
      null => context.l10n.downloadTaskFailed,
    };
    final active =
        state == DownloadTaskState.queued ||
        state == DownloadTaskState.downloading;
    return Padding(
      key: const Key('bookSourceDownloadInline'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state == DownloadTaskState.completed)
            const Icon(Icons.check_circle_rounded, size: 42)
          else
            LinearProgressIndicator(
              value: state == DownloadTaskState.failed ? 0 : task?.progress,
            ),
          const SizedBox(height: 14),
          Text(status, textAlign: TextAlign.center),
          if (task != null && task!.total > 0) ...[
            const SizedBox(height: 6),
            Text(
              context.l10n.bookSourceDownloadProgress(
                task!.completed,
                task!.total,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          if (active)
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onCancel,
                    child: Text(context.l10n.downloadTaskCancel),
                  ),
                ),
                Expanded(
                  child: FilledButton(
                    key: const Key('bookSourceDownloadBackgroundButton'),
                    onPressed: onBackground,
                    child: Text(context.l10n.downloadContinueInBackground),
                  ),
                ),
              ],
            )
          else if (state == DownloadTaskState.failed)
            FilledButton(onPressed: onRetry, child: Text(context.l10n.retry))
          else if (state == DownloadTaskState.cancelled)
            TextButton(onPressed: onBack, child: Text(context.l10n.back)),
        ],
      ),
    );
  }
}
