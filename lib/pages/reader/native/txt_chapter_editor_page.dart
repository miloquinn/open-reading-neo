import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/txt_edit_service.dart';

import 'txt_editor_copy.dart';

enum TxtChapterEditorResult { saved, restored }

class TxtChapterEditorOutcome {
  const TxtChapterEditorOutcome({
    required this.result,
    required this.anchorQuote,
    required this.offsetWithinQuote,
  });

  final TxtChapterEditorResult result;
  final String anchorQuote;
  final int offsetWithinQuote;
}

class TxtChapterEditorPage extends StatefulWidget {
  const TxtChapterEditorPage({
    super.key,
    required this.book,
    required this.chapterId,
    required this.prefaceTitle,
    required this.service,
    required this.onCommitMetadata,
  });

  final Book book;
  final String chapterId;
  final String prefaceTitle;
  final TxtEditService service;
  final Future<void> Function(TxtEditCommit commit) onCommitMetadata;

  @override
  State<TxtChapterEditorPage> createState() => _TxtChapterEditorPageState();
}

class _TxtChapterEditorPageState extends State<TxtChapterEditorPage> {
  late final Future<TxtEditableChapter> _chapterFuture;
  TextEditingController? _controller;
  bool _busy = false;
  bool _allowExit = false;
  bool _askingToLeave = false;
  String? _originalText;

  void _finish([TxtChapterEditorOutcome? outcome]) {
    if (!mounted) return;
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(outcome);
    });
  }

  Future<void> _tryLeave() async {
    if (_busy || _askingToLeave) return;
    _askingToLeave = true;
    final copy = TxtEditorCopy.of(context);
    try {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(copy.discardChanges),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(copy.keepEditing),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(copy.discard),
            ),
          ],
        ),
      );
      if (discard == true) _finish();
    } finally {
      _askingToLeave = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _chapterFuture = widget.service.loadChapter(
      book: widget.book,
      chapterId: widget.chapterId,
      prefaceTitle: widget.prefaceTitle,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _save(TxtEditableChapter chapter) async {
    if (_busy) return;
    var allowConversion = false;
    if (chapter.encoding == TxtEditEncoding.requiresUtf8Conversion) {
      final copy = TxtEditorCopy.of(context);
      allowConversion =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(copy.conversionTitle),
              content: Text(copy.conversionBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(copy.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(copy.convertAndSave),
                ),
              ],
            ),
          ) ??
          false;
      if (!allowConversion || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await widget.service.saveChapter(
        book: widget.book,
        chapterId: widget.chapterId,
        prefaceTitle: widget.prefaceTitle,
        editedText: _controller!.text,
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: allowConversion,
        onCommitted: widget.onCommitMetadata,
      );
      if (mounted) {
        final text = _controller!.text;
        final caret = _controller!.selection.baseOffset.clamp(0, text.length);
        var quoteStart = (caret - 40).clamp(0, text.length);
        var quoteEnd = (caret + 40).clamp(quoteStart, text.length);
        if (quoteStart > 0 &&
            _isLowSurrogate(text.codeUnitAt(quoteStart)) &&
            _isHighSurrogate(text.codeUnitAt(quoteStart - 1))) {
          quoteStart--;
        }
        if (quoteEnd < text.length &&
            quoteEnd > 0 &&
            _isLowSurrogate(text.codeUnitAt(quoteEnd)) &&
            _isHighSurrogate(text.codeUnitAt(quoteEnd - 1))) {
          quoteEnd--;
        }
        _finish(
          TxtChapterEditorOutcome(
            result: TxtChapterEditorResult.saved,
            anchorQuote: text.substring(quoteStart, quoteEnd),
            offsetWithinQuote: caret - quoteStart,
          ),
        );
      }
    } on TxtEditFailure catch (error) {
      if (!mounted) return;
      final copy = TxtEditorCopy.of(context);
      final message = error.code == 'chapter_structure_changed'
          ? copy.structureChanged
          : error.code == 'chapter_changed' || error.code == 'source_changed'
          ? copy.sourceChanged
          : error.code == 'section_too_large'
          ? copy.sectionTooLarge
          : copy.saveFailed;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      setState(() => _busy = false);
    }
  }

  Future<void> _showHistory() async {
    final versions = await widget.service.listVersions(widget.book);
    if (!mounted) return;
    final copy = TxtEditorCopy.of(context);
    final selected = await showModalBottomSheet<TxtEditVersion>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: versions.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text(copy.noVersions)),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: versions.length,
                itemBuilder: (context, index) {
                  final version = versions[index];
                  return ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: Text(
                      DateFormat.yMd().add_Hm().format(version.createdAt),
                    ),
                    subtitle: Text(version.contentHash.substring(0, 12)),
                    onTap: () => Navigator.pop(context, version),
                  );
                },
              ),
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(copy.restore),
            content: Text(copy.restoreConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(copy.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(copy.restore),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.service.restoreVersion(
        book: widget.book,
        version: selected,
        onCommitted: widget.onCommitMetadata,
      );
      if (mounted) {
        _finish(
          const TxtChapterEditorOutcome(
            result: TxtChapterEditorResult.restored,
            anchorQuote: '',
            offsetWithinQuote: 0,
          ),
        );
      }
    } on TxtEditFailure {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(copy.saveFailed)));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = TxtEditorCopy.of(context);
    return FutureBuilder<TxtEditableChapter>(
      future: _chapterFuture,
      builder: (context, snapshot) {
        final chapter = snapshot.data;
        if (chapter != null && _controller == null) {
          _originalText = chapter.text;
          _controller = TextEditingController(text: chapter.text);
        }
        return PopScope<TxtChapterEditorOutcome>(
          canPop:
              _allowExit || (!_busy && (_controller?.text == _originalText)),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _tryLeave();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(chapter?.title ?? copy.editChapter),
              actions: [
                IconButton(
                  tooltip: copy.versionHistory,
                  onPressed: _busy ? null : _showHistory,
                  icon: const Icon(Icons.history_rounded),
                ),
                TextButton(
                  onPressed: chapter == null || _busy
                      ? null
                      : () => _save(chapter),
                  child: Text(copy.save),
                ),
              ],
            ),
            body: chapter == null
                ? snapshot.hasError
                      ? Center(
                          child: Text(
                            snapshot.error is TxtEditFailure &&
                                    (snapshot.error! as TxtEditFailure).code ==
                                        'section_too_large'
                                ? copy.sectionTooLarge
                                : copy.sourceChanged,
                          ),
                        )
                      : const Center(child: CircularProgressIndicator())
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: TextField(
                        key: const ValueKey('txt-chapter-editor-field'),
                        controller: _controller,
                        onChanged: (_) => setState(() {}),
                        enabled: !_busy,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 17, height: 1.65),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(20),
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;
bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;
