/// Speech-only normalization. Internal UTF-16 offsets stay aligned with the
/// source; [leadingOffset] accounts for trimming before handing text to TTS.
class ReaderAloudText {
  ReaderAloudText(String source) {
    final normalized = source
        .replaceAllMapped(_silentMarks, (match) {
          final isMultiplication =
              (match[0] == '*' || match[0] == '＊') &&
              match.start > 0 &&
              match.end < source.length &&
              _number.hasMatch(source[match.start - 1]) &&
              _number.hasMatch(source[match.end]);
          return isMultiplication ? '*' : ' ';
        })
        .replaceAllMapped(_singleQuotes, (match) {
          // Apostrophes belong to words (don't, O’Neill); quotation marks do not.
          final insideWord =
              match.start > 0 &&
              match.end < source.length &&
              _apostropheLetter.hasMatch(source[match.start - 1]) &&
              _apostropheLetter.hasMatch(source[match.end]);
          return insideWord ? "'" : ' ';
        })
        .replaceAllMapped(_pauses, (match) => ','.padRight(match[0]!.length));
    leadingOffset = normalized.length - normalized.trimLeft().length;
    text = _readable.hasMatch(normalized) ? normalized.trim() : '';
  }

  late final String text;
  late final int leadingOffset;

  // Keep sentence punctuation, apostrophes within words, numbers and operators.
  // Remove only typographic wrappers and common decorative/formatting marks.
  static final _silentMarks = RegExp(
    '[“”„‟〝〞〟「」『』«»《》〈〉【】〔〕〖〗〘〙〚〛（）()\\[\\]{}｛｝"'
    '#＃*＊_＿`｀|｜•●○◆◇■□★☆※]',
  );
  static final _pauses = RegExp(r'[…⋯]+|\.{2,}|[—–―〜～~]+|-{2,}');
  static final _singleQuotes = RegExp("['‘’‚‛＇]");
  static final _apostropheLetter = RegExp(
    r'[\p{Script=Latin}\p{Script=Cyrillic}\p{M}]',
    unicode: true,
  );
  static final _number = RegExp(r'\p{N}', unicode: true);
  static final _readable = RegExp(r'[\p{L}\p{N}]', unicode: true);
}
