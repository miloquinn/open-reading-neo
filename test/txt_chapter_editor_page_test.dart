import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/native/txt_chapter_editor_page.dart';
import 'package:xxread/services/books/txt_edit_service.dart';

void main() {
  testWidgets('back preserves a dirty draft unless discard is chosen', (
    tester,
  ) async {
    await _open(tester, _EditorService());
    await tester.enterText(find.byType(TextField), 'Changed text');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Changed text'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.byType(TxtChapterEditorPage), findsNothing);
  });

  testWidgets('back cannot detach the reader from an in-flight commit', (
    tester,
  ) async {
    final service = _EditorService();
    final commit = Completer<void>();
    service.commit = commit.future;
    await _open(tester, service);
    await tester.enterText(find.byType(TextField), 'Saved text');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pageBack();
    await tester.pump();
    expect(find.byType(TxtChapterEditorPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    commit.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TxtChapterEditorPage), findsNothing);
    expect(service.savedText, 'Saved text');
  });
}

Future<void> _open(WidgetTester tester, TxtEditService service) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TxtChapterEditorPage(
                  book: Book(
                    id: 1,
                    title: 'Book',
                    filePath: '/fixture/book.txt',
                    format: 'txt',
                  ),
                  chapterId: 'txt-0',
                  prefaceTitle: 'Preface',
                  service: service,
                  onCommitMetadata: (_) async {},
                ),
              ),
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

class _EditorService extends TxtEditService {
  Future<void> commit = Future.value();
  String? savedText;

  @override
  Future<TxtEditableChapter> loadChapter({
    required Book book,
    required String chapterId,
    required String prefaceTitle,
  }) async => const TxtEditableChapter(
    id: 'txt-0',
    title: 'Chapter',
    text: 'Original text',
    encoding: TxtEditEncoding.utf8,
    baseContentHash: 'original',
  );

  @override
  Future<TxtEditCommit> saveChapter({
    required Book book,
    required String chapterId,
    required String prefaceTitle,
    required String editedText,
    required String expectedBaseContentHash,
    required bool allowUtf8Conversion,
    Future<void> Function(TxtEditCommit commit)? onCommitted,
  }) async {
    await commit;
    savedText = editedText;
    final result = TxtEditCommit(
      contentHash: 'new',
      modifiedAt: DateTime.now(),
      textEncoding: 'utf8',
    );
    await onCommitted?.call(result);
    return result;
  }
}
