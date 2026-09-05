/// The portable java.htmlFormat contract from HtmlFormatter.formatKeepImg.
/// Keep entities and relative image URLs intact; this API has no response base.
String sourceScriptFormatKeepImg(String value) {
  final formatted = value
      .replaceAll(RegExp(r'(&nbsp;)+'), ' ')
      .replaceAll(RegExp(r'&(?:ensp|emsp);'), ' ')
      .replaceAll(RegExp(r'&(?:thinsp|zwnj|zwj);|[\u2009\u200c\u200d]'), '')
      .replaceAll(RegExp(r'</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>'), '\n')
      .replaceAll(RegExp(r'<!--[^>]*-->'), '')
      .replaceAll(RegExp(r'</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>'), '')
      // Android's whitespace matching includes the inserted paragraph indent.
      .replaceAll(RegExp(r'\s*\n+\s*'), '\n　　')
      .replaceAll(RegExp(r'^\s+'), '　　')
      .replaceAll(RegExp(r'\s+$'), '');
  return formatted.replaceAllMapped(_imagePattern, (match) {
    final url = match.group(1) ?? match.group(2) ?? match.group(3)!;
    return '<img src="${url.trim()}">';
  });
}

// Try option-bearing src first so quotes inside nested headers stay untouched.
final _imagePattern = RegExp(
  r'''<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>|<img[^>]*\s(?:data-src|src)\s*=\s*['"]([^'">]+)['"][^>]*>|<img[^>]*\sdata-[^=>]*=\s*['"]([^'">]*)['"][^>]*>''',
  caseSensitive: false,
);
