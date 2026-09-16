import 'dart:convert';

import '../../models/book.dart';

enum SourceBookCheckStatus {
  unchecked,
  current,
  available,
  needsMapping,
  failed,
}

/// Shelf-only metadata, stored beside (never inside) the source's variables.
/// A check timestamp is deliberately separate from an observed content update.
class SourceBookUpdateInfo {
  const SourceBookUpdateInfo({
    this.status = SourceBookCheckStatus.unchecked,
    this.checkedAt,
    this.updatedAt,
    this.chapterCount = 0,
    this.latestChapterId,
    this.latestChapter,
    this.newChapterCount = 0,
  });

  static const storageKey = '_openReadingUpdates';
  final SourceBookCheckStatus status;
  final DateTime? checkedAt;
  final DateTime? updatedAt;
  final int chapterCount;
  final String? latestChapterId;
  final String? latestChapter;
  final int newChapterCount;

  bool get hasNewChapters =>
      status == SourceBookCheckStatus.available || newChapterCount > 0;

  factory SourceBookUpdateInfo.fromBook(Book book) {
    try {
      final json = jsonDecode(book.sourceBookJson ?? '{}') as Map;
      final data = json[storageKey] as Map? ?? const {};
      return SourceBookUpdateInfo(
        status:
            SourceBookCheckStatus.values
                .where((s) => s.name == data['status'])
                .firstOrNull ??
            SourceBookCheckStatus.unchecked,
        checkedAt: DateTime.tryParse('${data['checkedAt']}'),
        updatedAt: DateTime.tryParse(
          '${data['updatedAt'] ?? json['updatedAt']}',
        ),
        chapterCount: (data['chapterCount'] as num?)?.toInt() ?? 0,
        latestChapterId: data['latestChapterId'] as String?,
        latestChapter:
            data['latestChapter'] as String? ??
            json['latestChapter'] as String?,
        newChapterCount: (data['newChapterCount'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const SourceBookUpdateInfo();
    }
  }

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'checkedAt': checkedAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'chapterCount': chapterCount,
    'latestChapterId': latestChapterId,
    'latestChapter': latestChapter,
    'newChapterCount': newChapterCount,
  };

  String encodeInto(Book book) => jsonEncode({
    ...jsonDecode(book.sourceBookJson!) as Map<String, dynamic>,
    storageKey: toJson(),
  });
}
