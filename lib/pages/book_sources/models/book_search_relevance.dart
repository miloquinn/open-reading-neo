// 文件说明：跨书源搜索结果的相关度打分，用于把更贴近关键词的结果排到前面。
// 技术要点：只影响展示顺序，不过滤结果——各书源自己的模糊匹配逻辑仍然生效。

import 'sourced_book.dart';

/// 根据书名/作者与搜索关键词的匹配程度打分，分值越大越相关。
int sourcedBookRelevance(String query, SourcedBook item) {
  final normalizedQuery = normalizeForRelevance(query);
  if (normalizedQuery.isEmpty) return 0;
  final title = normalizeForRelevance(item.book.title);
  if (title == normalizedQuery) return 4;
  if (title.startsWith(normalizedQuery)) return 3;
  if (title.contains(normalizedQuery)) return 2;
  final author = normalizeForRelevance(item.book.author);
  if (author.contains(normalizedQuery)) return 1;
  return 0;
}

/// 全角转半角、去除首尾空白与大小写差异，让打分不受书源格式差异影响。
String normalizeForRelevance(String value) {
  final buffer = StringBuffer();
  for (var rune in value.toLowerCase().trim().runes) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    if (rune <= 0x20) continue;
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}
