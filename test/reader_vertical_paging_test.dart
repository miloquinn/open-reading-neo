import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_vertical_paging.dart';
import 'package:xxread/widgets/reader_vertical_paging_surface.dart';
import 'package:xxread/widgets/reader_chapter_title_page.dart';

void main() {
  test('viewport chrome reserves fixed title and status slots', () {
    const metrics = ReaderViewportChromeMetrics(
      safeArea: ReaderSafeAreaMetrics(
        viewPadding: EdgeInsets.only(top: 24, bottom: 24),
        topMargin: 4,
        bottomMargin: 0,
      ),
    );

    expect(metrics.titleTop, 31);
    expect(metrics.contentTop, 56);
    expect(metrics.contentBottom, 26);
    expect(metrics.contentHeight(800), 718);
  });

  test('immersive viewport fills the whole screen regardless of margins', () {
    const metrics = ReaderViewportChromeMetrics(
      safeArea: ReaderSafeAreaMetrics(
        viewPadding: EdgeInsets.only(top: 44, bottom: 34),
        topMargin: 4,
        bottomMargin: 6,
      ),
      immersive: true,
    );

    expect(metrics.contentTop, 0);
    expect(metrics.contentBottom, 0);
    expect(metrics.contentHeight(800), 800);
  });

  test('viewport without a title slot only clears the status bar area', () {
    const metrics = ReaderViewportChromeMetrics(
      safeArea: ReaderSafeAreaMetrics(
        viewPadding: EdgeInsets.only(top: 24, bottom: 24),
        topMargin: 4,
        bottomMargin: 0,
      ),
      reservesTitle: false,
    );

    // 状态栏 24 + 上边距 4，不再附加章节标题条的 32。
    expect(metrics.contentTop, 28);
    // 底部页码条照常保留。
    expect(metrics.contentBottom, 26);
  });

  test('top bar style maps to one shared viewport chrome policy', () {
    const safeArea = ReaderSafeAreaMetrics(
      viewPadding: EdgeInsets.only(top: 24, bottom: 24),
      topMargin: 4,
      bottomMargin: 0,
    );

    final reader = readerViewportChromeForTopBar(
      safeArea: safeArea,
      topBarStyle: ReaderTopBarStyle.reader,
    );
    final system = readerViewportChromeForTopBar(
      safeArea: safeArea,
      topBarStyle: ReaderTopBarStyle.system,
    );
    final floating = readerViewportChromeForTopBar(
      safeArea: safeArea,
      topBarStyle: ReaderTopBarStyle.floating,
    );
    final hidden = readerViewportChromeForTopBar(
      safeArea: safeArea,
      topBarStyle: ReaderTopBarStyle.hidden,
    );

    expect(reader.contentTop, 56);
    expect(system.contentTop, 28);
    expect(floating.contentTop, 28);
    expect(floating.contentBottom, 26);
    expect(hidden.contentTop, 0);
    expect(hidden.contentBottom, 0);
  });

  test('primary visible item follows the viewport center', () {
    final primary = pickPrimaryReaderItem(const [
      ReaderVisibleItemPosition(
        index: 4,
        leadingEdge: -0.65,
        trailingEdge: 0.35,
      ),
      ReaderVisibleItemPosition(
        index: 5,
        leadingEdge: 0.35,
        trailingEdge: 1.35,
      ),
    ]);

    expect(primary?.index, 5);
  });

  test('chapter item position resolves its centered page', () {
    const position = ReaderVisibleItemPosition(
      index: 3,
      leadingEdge: -2.25,
      trailingEdge: 1.75,
    );

    expect(readerPageIndexWithinItem(position, 4), 2);
  });

  test('center refinement keeps the estimate when no cells are mounted', () {
    expect(
      readerPartIndexAtViewportCenter(
        estimatedIndex: 3,
        itemCount: 5,
        renderBoxAt: (_) => null,
        viewportCenterY: 400,
      ),
      3,
    );
  });

  test('source offset helpers fall back without rendered text', () {
    expect(
      readerSourceOffsetAtViewportCenter(
        paragraph: null,
        text: 'text',
        fallbackOffset: 42,
        sourceOffsetForTextOffset: (offset) => offset,
        viewportCenterY: 400,
      ),
      42,
    );
    expect(
      readerCaretDyForSourceOffset(
        paragraph: null,
        text: 'text',
        sourceOffset: 42,
        textOffsetForSourceOffset: (offset) => offset,
      ),
      isNull,
    );
  });

  testWidgets('mounted paragraph helpers preserve text/source mapping', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 180,
            child: KeyedSubtree(
              key: key,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ReaderInlineChapterTitle(
                    title: 'Chapter heading',
                    bodyStyle: TextStyle(fontSize: 16),
                  ),
                  Text('alpha beta gamma'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final paragraph = readerParagraphForKey(key)!;
    expect(paragraph.text.toPlainText(), 'alpha beta gamma');
    final globalTop = paragraph.localToGlobal(Offset.zero).dy;
    final centerY = globalTop + paragraph.size.height / 2;
    final expectedTextOffset = paragraph
        .getPositionForOffset(
          Offset(paragraph.size.width / 2, paragraph.size.height / 2),
        )
        .offset;

    expect(
      readerSourceOffsetAtViewportCenter(
        paragraph: paragraph,
        text: 'alpha beta gamma',
        fallbackOffset: 100,
        sourceOffsetForTextOffset: (offset) => 100 + offset,
        viewportCenterY: centerY,
      ),
      100 + expectedTextOffset,
    );
    expect(
      readerCaretDyForSourceOffset(
        paragraph: paragraph,
        text: 'alpha beta gamma',
        sourceOffset: 100 + expectedTextOffset,
        textOffsetForSourceOffset: (offset) => offset - 100,
      ),
      paragraph
          .getOffsetForCaret(
            TextPosition(offset: expectedTextOffset),
            Rect.zero,
          )
          .dy,
    );
  });

  testWidgets('mounted page cells refine the viewport-center page', (
    tester,
  ) async {
    final keys = List.generate(3, (_) => GlobalKey());
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Column(
            children: [
              for (final key in keys)
                SizedBox(key: key, width: 100, height: 100),
            ],
          ),
        ),
      ),
    );

    expect(
      readerPartIndexAtViewportCenter(
        estimatedIndex: 0,
        itemCount: keys.length,
        renderBoxAt: (index) =>
            keys[index].currentContext!.findRenderObject()! as RenderBox,
        viewportCenterY: 150,
      ),
      1,
    );
  });
}
