import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../book_sources/services/book_source_import_analyzer.dart';
import '../../../utils/localization_extension.dart';
import '../controllers/book_source_add_controller.dart';
import 'book_source_add_panel.dart';
import 'book_source_dedupe_review_sheet.dart';

/// Owns the import route and its asynchronous work for exactly one open session.
class BookSourceAddFlow extends StatefulWidget {
  const BookSourceAddFlow({
    super.key,
    required this.sheet,
    required this.additionalProtocolsEnabled,
    this.createController,
    this.pickFile,
  });

  final bool sheet;
  final bool additionalProtocolsEnabled;
  final BookSourceAddController Function()? createController;
  final Future<FilePickerResult?> Function()? pickFile;

  @override
  State<BookSourceAddFlow> createState() => _BookSourceAddFlowState();
}

class _BookSourceAddFlowState extends State<BookSourceAddFlow> {
  late final BookSourceAddController _controller;
  final _textController = TextEditingController();
  var _responsibilityAccepted = false;
  var _mode = BookSourceAddMode.link;
  var _pickingFile = false;
  String? _fileName;
  String _lastInput = '';

  @override
  void initState() {
    super.initState();
    _controller = (widget.createController ?? BookSourceAddController.new)()
      ..addListener(_onChanged);
    _textController.addListener(_onInputChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onInputChanged() {
    final input = _textController.text;
    if (input == _lastInput) return;
    _lastInput = input;
    if (!_controller.state.loading) _controller.clear();
  }

  Future<void> _chooseFile() async {
    if (_pickingFile || _controller.state.loading) return;
    setState(() => _pickingFile = true);
    try {
      final result = await (widget.pickFile ?? _pickJsonFile)();
      if (!mounted || result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        _controller.setError(context.l10n.bookSourcesImportFileUnreadable);
        return;
      }
      setState(() {
        _fileName = file.name;
        _pickingFile = false;
      });
      await _controller.analyzeBytes(bytes);
    } on Object catch (error) {
      if (mounted) _controller.setError(error);
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  static Future<FilePickerResult?> _pickJsonFile() => FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    allowMultiple: false,
    withData: true,
  );

  Future<void> _analyzeLink() async {
    if (_controller.state.loading || !_responsibilityAccepted) return;
    FocusScope.of(context).unfocus();
    await _controller.analyzeUrl(_textController.text);
  }

  Future<void> _add() async {
    if (!_responsibilityAccepted || _controller.state.loading) return;
    final analysis = _controller.state.analysis;
    if (analysis == null) return;
    if (analysis.kind == BookSourceImportKind.additional &&
        !widget.additionalProtocolsEnabled) {
      _controller.setError(context.l10n.bookSourcesAdvancedFeatureRequired);
      return;
    }
    final result = await _controller.commit();
    if (mounted && result != null) Navigator.pop(context, result);
  }

  Future<void> _reviewDedupe() async {
    final preview = _controller.state.analysis?.additionalPreview;
    if (preview == null ||
        preview.dedupeResult.groups.isEmpty ||
        _controller.state.loading) {
      return;
    }
    final generation = _controller.state.generation;
    final selection =
        await showModalBottomSheet<BookSourceImportDedupeSelection>(
          context: context,
          useSafeArea: true,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (_) => BookSourceImportDedupeReviewSheet(preview: preview),
        );
    if (!mounted ||
        selection == null ||
        generation != _controller.state.generation) {
      return;
    }
    if (selection.preview case final updated?) {
      _controller.setDedupePreview(updated);
    }
  }

  void _cancel() {
    if (_controller.state.phase == BookSourceAddPhase.saving) return;
    _controller.cancelAnalysis();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onInputChanged)
      ..dispose();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return PopScope(
      canPop: state.phase != BookSourceAddPhase.saving,
      child: BookSourceAddPanel(
        controller: _textController,
        connecting: state.loading,
        phase: state.phase,
        pickingFile: _pickingFile,
        fileName: _fileName,
        responsibilityAccepted: _responsibilityAccepted,
        mode: _mode,
        analysis: state.analysis,
        errorText: state.error?.toString(),
        errorSummary: state.error is TimeoutException
            ? context.l10n.bookSourcesImportTimedOut
            : state.error is String
            ? state.error as String
            : null,
        importUnavailableReason:
            state.analysis?.kind == BookSourceImportKind.additional &&
                !widget.additionalProtocolsEnabled
            ? context.l10n.bookSourcesAdvancedFeatureRequired
            : null,
        sheet: widget.sheet,
        onModeChanged: (mode) {
          setState(() {
            _mode = mode;
            _fileName = null;
          });
          _controller.clear();
        },
        onResponsibilityChanged: (value) =>
            setState(() => _responsibilityAccepted = value),
        onCancel: _cancel,
        onAnalyzeLink: () => unawaited(_analyzeLink()),
        onChooseFile: () => unawaited(_chooseFile()),
        onAdd: () => unawaited(_add()),
        onReviewDedupe: () => unawaited(_reviewDedupe()),
      ),
    );
  }
}
