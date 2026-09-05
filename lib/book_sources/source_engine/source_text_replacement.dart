import '../protocol/book_source_protocol.dart';
import 'rules/source_rule_parser.dart';
import 'rules/source_rule_regex.dart';
import 'source_content_images.dart';

typedef SourceTextReplacement = ({
  String content,
  List<SourceContentImagePage> pages,
});

/// Applies a chapter-wide replacement while retaining the response base for
/// each output span. Image extraction can then resolve relative URLs from the
/// page that produced them, including URLs rewritten by the replacement.
/// A replacement that explicitly moves a capture across page boundaries is
/// attributed to the page where the complete regex match starts.
SourceTextReplacement replaceTextPages(
  List<SourceContentImagePage> pages,
  String rule,
) {
  final input = pages.map((page) => page.content).join('\n\n');
  if (rule.trim().isEmpty) return (content: input, pages: pages);
  final transformed = splitSourceRuleTransform(
    rule.trim().startsWith('##') ? rule : '##$rule',
  );
  if (transformed.pattern == null) return (content: input, pages: pages);
  try {
    final pattern = RegExp(
      transformed.pattern!,
      multiLine: true,
      dotAll: false,
    );
    if (pages.isEmpty) {
      return (
        content: replaceSourceRegex(input, pattern, transformed.replacement),
        pages: const [],
      );
    }

    final spans = _pageSpans(pages);
    final output = _ReplacementOutput();
    var cursor = 0;
    for (final match in pattern.allMatches(input)) {
      _addOriginalRange(input, cursor, match.start, spans, output.add);
      output.add(
        SourceRegexRuleContext(match).expand(transformed.replacement),
        _baseAt(match.start, spans),
      );
      cursor = match.end;
    }
    _addOriginalRange(input, cursor, input.length, spans, output.add);
    return output.finish();
  } on FormatException {
    throw const BookSourceProtocolException(
      'reading source replacement contains an invalid regular expression.',
    );
  }
}

List<_PageSpan> _pageSpans(List<SourceContentImagePage> pages) {
  final spans = <_PageSpan>[];
  var start = 0;
  for (var index = 0; index < pages.length; index++) {
    final separatorLength = index == pages.length - 1 ? 0 : 2;
    final end = start + pages[index].content.length + separatorLength;
    spans.add(_PageSpan(start, end, pages[index].baseUri));
    start = end;
  }
  return spans;
}

void _addOriginalRange(
  String input,
  int start,
  int end,
  List<_PageSpan> spans,
  void Function(String, Uri) add,
) {
  for (final span in spans) {
    final partStart = start > span.start ? start : span.start;
    final partEnd = end < span.end ? end : span.end;
    if (partStart < partEnd) {
      add(input.substring(partStart, partEnd), span.baseUri);
    }
  }
}

Uri _baseAt(int offset, List<_PageSpan> spans) {
  for (final span in spans) {
    if (offset < span.end) return span.baseUri;
  }
  return spans.last.baseUri;
}

class _PageSpan {
  const _PageSpan(this.start, this.end, this.baseUri);

  final int start;
  final int end;
  final Uri baseUri;
}

class _ReplacementOutput {
  final StringBuffer _content = StringBuffer();
  final List<SourceContentImagePage> _pages = [];
  StringBuffer _current = StringBuffer();
  Uri? _currentBase;

  void add(String text, Uri baseUri) {
    if (text.isEmpty) return;
    _content.write(text);
    if (_currentBase != null && _currentBase != baseUri) _flush();
    _currentBase = baseUri;
    _current.write(text);
  }

  SourceTextReplacement finish() {
    _flush();
    return (content: _content.toString(), pages: _pages);
  }

  void _flush() {
    if (_currentBase == null || _current.isEmpty) return;
    _pages.add((content: _current.toString(), baseUri: _currentBase!));
    _current = StringBuffer();
  }
}
