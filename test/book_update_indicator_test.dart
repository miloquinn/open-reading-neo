import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/source_book_update_info.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/widgets/book_update_indicator.dart';

void main() {
  for (final status in [
    SourceBookCheckStatus.available,
    SourceBookCheckStatus.failed,
  ]) {
    for (final size in [const Size(64, 96), const Size(120, 180)]) {
      testWidgets(
        'new chapters retain one small top-right cover marker at $size ($status)',
        (tester) async {
          final book = Book(
            title: 'Book',
            filePath: '',
            format: 'source',
            sourceBookJson: '{}',
          );
          final updated = book.copyWith(
            sourceBookJson: SourceBookUpdateInfo(
              status: status,
              newChapterCount: 2,
            ).encodeInto(book),
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: BookUpdateIndicator(
                      book: updated,
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final badge = find.byKey(
            const ValueKey('book-cover-update-indicator'),
          );
          expect(badge, findsOneWidget);
          expect(tester.getSize(badge), const Size(18, 18));
          final cover = tester.getRect(find.byType(BookUpdateIndicator));
          final marker = tester.getRect(badge);
          expect(marker.top - cover.top, 4);
          expect(cover.right - marker.right, 4);
          expect(find.text('书籍更新'), findsNothing);
          expect(find.text('有新章节'), findsNothing);
          expect(find.byTooltip('有新章节'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            MaterialApp(
              home: BookUpdateIndicator(
                book: book,
                child: const SizedBox(width: 64, height: 96),
              ),
            ),
          );
          expect(
            find.byKey(const ValueKey('book-cover-update-indicator')),
            findsNothing,
          );
        },
      );
    }
  }
}
