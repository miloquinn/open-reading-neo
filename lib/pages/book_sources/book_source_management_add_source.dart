part of 'book_source_management_page.dart';

extension _BookSourceManagementAddSource on _BookSourceManagementPageState {
  Future<void> _showAddSourceDialog() async {
    final textController = TextEditingController();
    final addController = BookSourceAddController();
    var responsibilityAccepted = false;
    var mode = BookSourceAddMode.link;

    Future<void> chooseFile(StateSetter setRouteState) async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > SourceImportService.maxImportBytes) {
        setRouteState(() {});
        _showAddFileError(addController, 'Source file exceeds 64 MiB.');
        return;
      }
      final bytes = file.bytes;
      if (bytes == null) {
        _showAddFileError(addController, 'Could not read source file.');
        setRouteState(() {});
        return;
      }
      final pending = addController.analyzeBytes(bytes);
      setRouteState(() {});
      await pending;
      setRouteState(() {});
    }

    Future<void> analyzeLink(StateSetter setRouteState) async {
      final pending = addController.analyzeUrl(textController.text);
      setRouteState(() {});
      await pending;
      setRouteState(() {});
    }

    Future<void> addDetected(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final detected = addController.state.analysis;
      if (detected == null) return;
      if (detected.kind == BookSourceImportKind.additional &&
          !_additionalProtocolsEnabled()) {
        _showAddFileError(
          addController,
          context.l10n.bookSourcesAdvancedFeatureRequired,
        );
        setRouteState(() {});
        return;
      }
      final pending = addController.commit();
      setRouteState(() {});
      final result = await pending;
      if (!mounted || !routeContext.mounted) return;
      setRouteState(() {});
      if (result == null) return;
      Navigator.pop(routeContext);
      _controller.replaceSources(result.sources);
      showSideToast(context, switch (result.analysis.kind) {
        BookSourceImportKind.orsp =>
          '${context.l10n.bookSourcesAdded}: ${result.analysis.sources.single.name}',
        BookSourceImportKind.additional when result.conflictedCount > 0 =>
          context.l10n.additionalSourcesImportedWithConflicts(
            result.importedCount,
            result.conflictedCount,
          ),
        BookSourceImportKind.additional =>
          context.l10n.additionalSourcesImported(result.importedCount),
      }, kind: SideToastKind.success);
    }

    Future<void> reviewDedupe(StateSetter setRouteState) async {
      final preview = addController.state.analysis?.additionalPreview;
      if (preview == null || preview.dedupeResult.groups.isEmpty) return;
      final selection =
          await showModalBottomSheet<BookSourceImportDedupeSelection>(
            context: context,
            useSafeArea: true,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (context) =>
                BookSourceImportDedupeReviewSheet(preview: preview),
          );
      if (selection == null) return;
      addController.setDedupeMode(selection.mode);
      addController.setSelectedSourceIndices(selection.selectedIndices);
      setRouteState(() {});
    }

    Widget buildPanel(
      BuildContext routeContext,
      StateSetter setRouteState, {
      required bool sheet,
    }) {
      final addState = addController.state;
      return BookSourceAddPanel(
        controller: textController,
        connecting: addState.loading,
        responsibilityAccepted: responsibilityAccepted,
        mode: mode,
        analysis: addState.analysis,
        errorText: addState.error?.toString(),
        sheet: sheet,
        onModeChanged: (value) => setRouteState(() {
          mode = value;
          addController.clear();
        }),
        onResponsibilityChanged: (value) =>
            setRouteState(() => responsibilityAccepted = value),
        onCancel: () => Navigator.pop(routeContext),
        onAnalyzeLink: () => unawaited(analyzeLink(setRouteState)),
        onChooseFile: () => unawaited(chooseFile(setRouteState)),
        onAdd: () => unawaited(addDetected(routeContext, setRouteState)),
        onReviewDedupe: () => unawaited(reviewDedupe(setRouteState)),
      );
    }

    if (LayoutHelper.isMobile(context)) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: buildPanel(sheetContext, setSheetState, sheet: true),
            ),
          ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        barrierDismissible: !addController.state.loading,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
              child: buildPanel(dialogContext, setDialogState, sheet: false),
            ),
          ),
        ),
      );
    }
    textController.dispose();
    addController.dispose();
  }

  void _showAddFileError(BookSourceAddController controller, Object error) {
    controller.setError(error);
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
