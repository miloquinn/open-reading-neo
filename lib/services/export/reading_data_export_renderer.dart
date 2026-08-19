import 'package:xxread/models/book_note.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';

class ReadingDataMarkdownRenderer {
  const ReadingDataMarkdownRenderer();

  String render(PreparedReadingDataExport document) {
    final out = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${_yaml(document.book.title)}')
      ..writeln('author: ${_yaml(document.book.author)}')
      ..writeln(
        'exported_at: ${_yaml(document.preparedAt.toUtc().toIso8601String())}',
      )
      ..writeln('annotation_count: ${document.counts.total}')
      ..writeln('---')
      ..writeln()
      ..writeln('# 《${_text(document.book.title)}》')
      ..writeln()
      ..writeln(
        '> **${_text(document.labels.author)}**：${_text(document.book.author)}  ',
      )
      ..writeln(
        '> **${_text(document.labels.wholeBook)}** · '
        '${document.counts.highlights} ${_text(document.labels.highlight)} · '
        '${document.counts.underlines} ${_text(document.labels.underline)} · '
        '${document.counts.notes} ${_text(document.labels.note)}  ',
      )
      ..writeln(
        '> **${_text(document.labels.exportedAt)}**：'
        '${_text(document.preparedAt.toLocal().toIso8601String())}',
      )
      ..writeln()
      ..writeln('---')
      ..writeln();

    String? chapter;
    for (final annotation in document.annotations) {
      final nextChapter = annotation.chapter.trim().isEmpty
          ? document.labels.unknownChapter
          : annotation.chapter.trim();
      if (chapter != nextChapter) {
        chapter = nextChapter;
        out
          ..writeln('## ${_text(chapter)}')
          ..writeln();
      }
      out
        ..writeln('### ${_text(_typeLabel(annotation, document.labels))}')
        ..writeln();
      if (annotation.content.trim().isNotEmpty) {
        for (final line in _safe(annotation.content).split('\n')) {
          out.writeln(line.isEmpty ? '>' : '> $line');
        }
        out.writeln();
      }
      final note = annotation.readerNote?.trim();
      if (note != null && note.isNotEmpty) {
        out
          ..writeln('**${_text(document.labels.myNote)}**')
          ..writeln()
          ..writeln(_text(note))
          ..writeln();
      }
      if (annotation.pageNumber != null) {
        out
          ..writeln(
            '`'
            '${_text(document.labels.pageLabel(annotation.pageNumber! + 1))}'
            '`',
          )
          ..writeln();
      }
    }
    return '${out.toString().trimRight()}\n';
  }

  String _typeLabel(BookNote note, ReadingDataExportLabels labels) =>
      switch (note.type) {
        'highlight' => labels.highlight,
        'underline' => labels.underline,
        'note' => labels.note,
        _ => note.type,
      };

  String _yaml(String value) {
    final normalized = _safe(
      value,
    ).replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n');
    return '"$normalized"';
  }

  String _text(String value) => _safe(value)
      .replaceAll('\\', '\\\\')
      .replaceAll(RegExp(r'([`*_{}\[\]()#+.!|>~-])'), r'\$1');

  String _safe(String value) => value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
