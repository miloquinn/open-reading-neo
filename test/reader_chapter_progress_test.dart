import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_progress_footer.dart';
import 'package:xxread/widgets/reader_chapter_progress_setting_tile.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';

void main() {
  test(
    'chapter progress defaults safely and survives other settings edits',
    () async {
      const store = ReaderSettingsStore();
      SharedPreferences.setMockInitialValues({});
      expect(
        (await store.load()).chapterProgressStyle,
        ReaderChapterProgressStyle.hidden,
      );
      for (final style in ReaderChapterProgressStyle.values) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(ReaderSettingsStore.fontSizeKey, 27);
        await store.saveChapterProgressStyle(style);
        expect(prefs.getDouble(ReaderSettingsStore.fontSizeKey), 27);
        await store.save((await store.load()).copyWith(fontSize: 24));
        expect((await store.load()).chapterProgressStyle, style);
      }
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.chapterProgressStyleKey: 'future-style',
      });
      expect(
        (await store.load()).chapterProgressStyle,
        ReaderChapterProgressStyle.hidden,
      );
    },
  );

  testWidgets(
    'labels count subsequent chapters and suppress unknown positions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              String label(
                ReaderChapterProgressStyle style,
                int index,
                int count,
              ) => formatReaderChapterProgress(
                context,
                style: style,
                chapterIndex: index,
                chapterCount: count,
              );
              expect(
                label(ReaderChapterProgressStyle.fraction, 157, 168),
                '158/168章',
              );
              expect(
                label(ReaderChapterProgressStyle.remaining, 9, 168),
                '后续158章',
              );
              expect(
                label(ReaderChapterProgressStyle.remaining, 167, 168),
                '后续0章',
              );
              expect(label(ReaderChapterProgressStyle.remaining, 0, 1), '后续0章');
              expect(label(ReaderChapterProgressStyle.hidden, 157, 168), '');
              expect(label(ReaderChapterProgressStyle.remaining, 0, 0), '');
              expect(label(ReaderChapterProgressStyle.fraction, -1, 168), '');
              expect(label(ReaderChapterProgressStyle.remaining, 168, 168), '');
              return const SizedBox();
            },
          ),
        ),
      );
    },
  );

  testWidgets(
    'three settings options update the selection and can be reopened',
    (tester) async {
      var selected = ReaderChapterProgressStyle.hidden;
      late StateSetter updateSelection;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateSelection = setState;
                return ReaderChapterProgressSettingTile(
                  style: selected,
                  onChanged: (style) => setState(() => selected = style),
                );
              },
            ),
          ),
        ),
      );
      for (final style in [
        ReaderChapterProgressStyle.fraction,
        ReaderChapterProgressStyle.remaining,
        ReaderChapterProgressStyle.hidden,
      ]) {
        await tester.tap(
          find.byKey(const ValueKey('reader-chapter-progress-tile')),
        );
        await tester.pumpAndSettle();
        expect(find.text('不显示'), findsWidgets);
        expect(find.text('158/168章'), findsWidgets);
        expect(find.text('后续158章'), findsWidgets);
        await tester.tap(
          find.byKey(ValueKey('reader-chapter-progress-${style.name}')),
        );
        await tester.pumpAndSettle();
        expect(selected, style);
      }
      // Parent-owned changes must also refresh the tile and selected radio.
      updateSelection(() => selected = ReaderChapterProgressStyle.fraction);
      await tester.pump();
      expect(find.text('158/168章'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('reader-chapter-progress-tile')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RadioGroup<ReaderChapterProgressStyle>>(
              find.byType(RadioGroup<ReaderChapterProgressStyle>),
            )
            .groupValue,
        ReaderChapterProgressStyle.fraction,
      );
    },
  );

  testWidgets(
    'chapter progress shares the leaf with page numbers at narrow widths',
    (tester) async {
      for (final placement in ReaderPageNumberPlacement.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 240,
                height: 400,
                child: ReaderPaperPageLeaf(
                  palette: ReaderThemes.day,
                  safeArea: const ReaderSafeAreaMetrics(
                    viewPadding: EdgeInsets.zero,
                    topMargin: 4,
                    bottomMargin: 0,
                  ),
                  metadata: const ReaderPaperPageMetadata(
                    pageIdentity: 'chapter-158:3',
                    layoutFingerprint: 'test',
                    themeId: 'day',
                    chapterTitle: 'Chapter',
                    pageNumber: 3,
                    pageCount: 12,
                  ),
                  chapterProgressLabel: '158/168章',
                  pageNumberPlacement: placement,
                  child: const Text('Body'),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('3 / 12'), findsOneWidget);
        expect(find.text('158/168章'), findsOneWidget);
        final chapter = tester.getRect(find.text('158/168章'));
        final page = tester.getRect(find.text('3 / 12'));
        expect(chapter.overlaps(page), isFalse);
        expect(
          chapter.center.dx < page.center.dx,
          placement == ReaderPageNumberPlacement.bottomRight,
        );
      }
    },
  );
}
