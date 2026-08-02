// 文件说明：将第三方书源返回的简介转换为适合界面展示的纯文本。

import 'package:html/parser.dart' as html_parser;

/// 清理书源简介中的 HTML、转义换行与不可见字符。
///
/// 只用于展示层，不修改书源配置或运行时返回的原始数据。
String normalizeBookSourceDescription(String value) {
  if (value.trim().isEmpty) return '';

  var normalized = value
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</\s*(?:p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<\s*li(?:\s[^>]*)?>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'\\r\\n|\\n|\\r'), '\n')
      .replaceAll(r'\t', ' ');

  // parseFragment 同时解码 &nbsp;、&amp; 等实体，并剥离残余标签。
  normalized = html_parser.parseFragment(normalized).text ?? '';
  // 某些书源会把标签本身再转义一层，例如 &lt;br&gt;。
  normalized = normalized
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</\s*(?:p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
        '\n',
      );
  normalized = html_parser.parseFragment(normalized).text ?? '';
  normalized = normalized
      .replaceAll('\u00a0', ' ')
      .replaceAll('\u200b', '')
      .replaceAll('\ufeff', '')
      .replaceAll(RegExp(r'[ \t\f\v]+'), ' ');

  final lines = normalized
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.trim())
      .toList(growable: false);
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
