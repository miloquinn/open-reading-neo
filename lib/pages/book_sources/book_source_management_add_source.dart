part of 'book_source_management_page.dart';

extension _BookSourceManagementAddSource on _BookSourceManagementPageState {
  Future<void> _showAddSourceDialog() async {
    final additionalEnabled = _additionalProtocolsEnabled();
    final BookSourceAddCommitResult? result;
    if (LayoutHelper.isMobile(context)) {
      result = await showModalBottomSheet<BookSourceAddCommitResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        enableDrag: false,
        isDismissible: false,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.88,
            ),
            child: BookSourceAddFlow(
              sheet: true,
              additionalProtocolsEnabled: additionalEnabled,
            ),
          ),
        ),
      );
    } else {
      result = await showDialog<BookSourceAddCommitResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 760),
            child: BookSourceAddFlow(
              sheet: false,
              additionalProtocolsEnabled: additionalEnabled,
            ),
          ),
        ),
      );
    }
    if (!mounted || result == null) return;
    _controller.replaceSources(result.sources);
    showSideToast(context, switch (result.analysis.kind) {
      BookSourceImportKind.orsp =>
        '${context.l10n.bookSourcesAdded}: ${result.analysis.sources.single.name}',
      BookSourceImportKind.additional when result.conflictedCount > 0 =>
        context.l10n.additionalSourcesImportedWithConflicts(
          result.importedCount,
          result.conflictedCount,
        ),
      BookSourceImportKind.additional => context.l10n.additionalSourcesImported(
        result.importedCount,
      ),
    }, kind: SideToastKind.success);
  }

  bool _additionalProtocolsEnabled() {
    try {
      return context
          .read<AppSettingsNotifier>()
          .additionalSourceProtocolsEnabled;
    } on ProviderNotFoundException {
      return false;
    }
  }

  void _showProtocolDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesProtocolDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.bookSourcesProtocolDialogBody,
                style: const TextStyle(height: 1.5),
              ),
              const SizedBox(height: 18),
              SelectableText(
                openReadingSourceProtocolRepositoryUrl,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openProtocolRepository,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(context.l10n.bookSourcesProtocolRepositoryOpen),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesClose),
          ),
        ],
      ),
    );
  }

  Future<void> _openProtocolRepository() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingSourceProtocolRepositoryUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesProtocolRepositoryOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openRightsReport() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingRightsReportUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesRightsReportOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<bool> _openExternalUrl(Uri url) {
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }
}
