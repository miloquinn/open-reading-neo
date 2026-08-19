import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/utils/reader_themes.dart';

class ReaderSearchDocument {
  const ReaderSearchDocument({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.text,
  });

  final int chapterIndex;
  final String chapterTitle;
  final String text;
}

class ReaderSearchResult {
  const ReaderSearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.offset,
    required this.excerpt,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int offset;
  final String excerpt;
}

typedef ReaderSearchLoader = Future<List<ReaderSearchDocument>> Function();

Future<void> showReaderSearchSheet(
  BuildContext context, {
  required ReaderThemePalette palette,
  required ReaderSearchLoader loadDocuments,
  required ValueChanged<ReaderSearchResult> onResultSelected,
  String initialQuery = '',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: palette.background,
  builder: (_) => _ReaderSearchSheet(
    palette: palette,
    loadDocuments: loadDocuments,
    onResultSelected: onResultSelected,
    initialQuery: initialQuery,
  ),
);

class _ReaderSearchSheet extends StatefulWidget {
  const _ReaderSearchSheet({
    required this.palette,
    required this.loadDocuments,
    required this.onResultSelected,
    required this.initialQuery,
  });

  final ReaderThemePalette palette;
  final ReaderSearchLoader loadDocuments;
  final ValueChanged<ReaderSearchResult> onResultSelected;
  final String initialQuery;

  @override
  State<_ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<_ReaderSearchSheet> {
  late final TextEditingController _controller;
  Timer? _debounce;
  List<ReaderSearchDocument>? _documents;
  List<ReaderSearchResult> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery.trim());
    if (_controller.text.isNotEmpty) _search(_controller.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(value));
  }

  Future<void> _search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _results = const []);
      return;
    }
    setState(() => _loading = true);
    final documents = _documents ?? await widget.loadDocuments();
    _documents = documents;
    final queryLower = query.toLowerCase();
    final results = <ReaderSearchResult>[];
    for (final document in documents) {
      final textLower = document.text.toLowerCase();
      var from = 0;
      while (results.length < 500) {
        final offset = textLower.indexOf(queryLower, from);
        if (offset < 0) break;
        final start = (offset - 24).clamp(0, document.text.length);
        final end = (offset + query.length + 48).clamp(
          start,
          document.text.length,
        );
        results.add(
          ReaderSearchResult(
            chapterIndex: document.chapterIndex,
            chapterTitle: document.chapterTitle,
            offset: offset,
            excerpt: document.text.substring(start, end).replaceAll('\n', ' '),
          ),
        );
        from = offset + query.length;
      }
      if (results.length >= 500) break;
    }
    if (!mounted || _controller.text.trim() != query) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return FractionallySizedBox(
      heightFactor: .9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('reader-full-text-search-field'),
                    controller: _controller,
                    autofocus: true,
                    onChanged: _onChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索本书内容',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _controller.clear();
                                _onChanged('');
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      filled: true,
                      fillColor: palette.controlFill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (!_loading && _controller.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '找到 ${_results.length} 处',
                  style: TextStyle(color: palette.secondaryText),
                ),
              ),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Text(
                      _controller.text.trim().isEmpty
                          ? '输入人物、地点或关键词'
                          : '没有找到相关内容',
                      style: TextStyle(color: palette.secondaryText),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: palette.text.withValues(alpha: .1)),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        title: Text(
                          result.chapterTitle,
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            result.excerpt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.secondaryText,
                              height: 1.45,
                            ),
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          widget.onResultSelected(result);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
