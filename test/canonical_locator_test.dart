import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/canonical_locator.dart';

void main() {
  group('TextAnchor', () {
    test('normalizes text and clamps offsets to non-negative values', () {
      final anchor = TextAnchor.create(
        quote: '  selected   text\r\nnext line  ',
        prefix: '  before   text ',
        suffix: ' after\rtext ',
        chapterId: ' chapter-1 ',
        startOffsetUtf16: -4,
        lengthUtf16: -2,
        offsetHint: -1,
      );

      expect(anchor.quote, 'selected text\nnext line');
      expect(anchor.prefix, 'before text');
      expect(anchor.suffix, 'after\ntext');
      expect(anchor.chapterId, 'chapter-1');
      expect(anchor.startOffsetUtf16, 0);
      expect(anchor.lengthUtf16, 0);
      expect(anchor.offsetHint, 0);
    });

    test('round-trips every persisted field through LocatorCodec', () {
      final anchor = TextAnchor.create(
        quote: 'selected text',
        prefix: 'before',
        suffix: 'after',
        chapterId: 'chapter-1',
        resourceHref: 'chapter-1.xhtml',
        startOffsetUtf16: 42,
        lengthUtf16: 13,
        offsetHint: 40,
      );

      final restored = LocatorCodec.decodeTextAnchor(
        LocatorCodec.encodeTextAnchor(anchor),
      );

      expect(restored, anchor);
    });
  });

  group('CanonicalLocator', () {
    test('builds and parses encoded text anchor hrefs', () {
      final locator = CanonicalLocator.fromComponents(
        format: BookFormat.txt,
        chapterId: '第一章/开端',
        offset: 17,
        excerpt: '你好 / world',
        progression: 0.25,
      );

      expect(locator.href, isNotNull);
      expect(CanonicalLocator.chapterIdFromHref(locator.href!), '第一章/开端');
      expect(CanonicalLocator.offsetFromHref(locator.href!), 17);
      expect(CanonicalLocator.excerptFromHref(locator.href!), '你好 / world');
      expect(locator.textAnchor?.quote, '你好 / world');
    });

    test('clamps progression and decodes unknown formats safely', () {
      expect(
        CanonicalLocator.fromProgression(
          format: BookFormat.epub,
          progression: 1.4,
        ).progression,
        1,
      );
      expect(
        CanonicalLocator.fromProgression(
          format: BookFormat.epub,
          progression: -0.4,
        ).progression,
        0,
      );

      final restored = CanonicalLocator.fromJson(const {
        'format': 'future-format',
        'progression': 0.5,
      });
      expect(restored.format, BookFormat.unknown);
    });

    test('round-trips every persisted field through LocatorCodec', () {
      final locator = CanonicalLocator.create(
        version: 2,
        format: BookFormat.epub,
        href: 'chapter-2.xhtml#section',
        chapterId: 'chapter-2',
        resourceHref: 'chapter-2.xhtml',
        progression: 0.75,
        positionHint: 8,
        totalPositionsHint: 12,
        fragments: const ['epubcfi(/6/4)', 'section'],
        textAnchor: TextAnchor.create(
          quote: 'anchor text',
          prefix: 'before',
          suffix: 'after',
          chapterId: 'chapter-2',
          startOffsetUtf16: 120,
          lengthUtf16: 11,
        ),
        contentSignature: 'sha256:content',
      );

      final restored = LocatorCodec.decodeCanonicalLocator(
        LocatorCodec.encodeCanonicalLocator(locator),
      );

      expect(restored, locator);
    });
  });

  group('RenderedLocator', () {
    test('uses the Flutter-native renderer when stored data is unknown', () {
      final locator = RenderedLocator.fromJson(const {
        'version': 1,
        'format': 'epub',
        'renderer': 'unknown-renderer',
        'href': 'chapter-1',
        'progression': 0.25,
        'position': 2,
        'totalPositions': 8,
      });

      expect(locator.renderer, ReaderRendererType.flutterNative);
    });

    test('round-trips generic renderer identifiers', () {
      final locator = RenderedLocator.create(
        version: 1,
        format: BookFormat.epub,
        renderer: ReaderRendererType.flutterNative,
        href: 'chapter-1',
        progression: 0.25,
        position: 2,
        totalPositions: 8,
      );

      final restored = RenderedLocator.fromJson(locator.toJson());

      expect(restored.renderer, ReaderRendererType.flutterNative);
      expect(restored.href, locator.href);
      expect(restored.position, locator.position);
    });

    test('normalizes boundaries and round-trips optional fields', () {
      final locator = RenderedLocator.create(
        version: 2,
        format: BookFormat.pdf,
        renderer: ReaderRendererType.platformNative,
        href: 'page-1',
        progression: 1.5,
        position: 0,
        totalPositions: 0,
        mediaType: 'application/pdf',
        title: 'Page 1',
        resourceProgression: 0.2,
        totalProgression: 0.4,
        fragments: const ['page=1'],
        textBefore: '  before   text ',
        textAfter: ' after\r\ntext ',
      );

      expect(locator.progression, 1);
      expect(locator.position, 1);
      expect(locator.totalPositions, 1);
      expect(locator.textBefore, 'before text');
      expect(locator.textAfter, 'after\ntext');
      expect(
        LocatorCodec.decodeRenderedLocator(
          LocatorCodec.encodeRenderedLocator(locator),
        ),
        locator,
      );
    });
  });

  group('AnnotationAnchor', () {
    test('round-trips nested locator and text anchor values', () {
      final textAnchor = TextAnchor.create(
        quote: 'highlighted text',
        chapterId: 'chapter-3',
        startOffsetUtf16: 9,
        lengthUtf16: 16,
      );
      final annotation = AnnotationAnchor(
        version: 2,
        kind: AnnotationTargetKind.note,
        locator: CanonicalLocator.create(
          format: BookFormat.txt,
          chapterId: 'chapter-3',
          progression: 0.3,
          textAnchor: textAnchor,
        ),
        textAnchor: textAnchor,
        selectedText: 'highlighted text',
        styleRaw: 'yellow',
        note: 'remember this',
        resolutionStatus: AnnotationResolutionStatus.quoteContext,
      );

      final restored = LocatorCodec.decodeAnnotationAnchor(
        LocatorCodec.encodeAnnotationAnchor(annotation),
      );

      expect(restored, annotation);
    });

    test('uses stable fallbacks for unknown enum values', () {
      final restored = AnnotationAnchor.fromJson({
        'kind': 'future-kind',
        'resolutionStatus': 'future-resolution',
        'locator': const {'format': 'txt'},
        'textAnchor': const {'quote': 'text'},
        'selectedText': 'text',
      });

      expect(restored.kind, AnnotationTargetKind.highlight);
      expect(restored.resolutionStatus, AnnotationResolutionStatus.unresolved);
    });
  });

  group('ReaderSelection', () {
    test('derives canonical text data and rendered location metadata', () {
      final anchor = TextAnchor.create(
        quote: 'selected text',
        prefix: 'canonical before',
        suffix: 'canonical after',
        chapterId: 'chapter-4',
        startOffsetUtf16: 25,
        lengthUtf16: 13,
      );
      final canonical = CanonicalLocator.create(
        format: BookFormat.epub,
        href: 'chapter-4.xhtml',
        chapterId: 'chapter-4',
        progression: 0.6,
        positionHint: 6,
        totalPositionsHint: 10,
        textAnchor: anchor,
      );
      final rendered = RenderedLocator.create(
        format: BookFormat.epub,
        renderer: ReaderRendererType.nativeExtension,
        href: 'chapter-4.xhtml',
        progression: 0.7,
        position: 7,
        totalPositions: 11,
        textBefore: 'rendered before',
        textAfter: 'rendered after',
      );

      final selection = ReaderSelection.fromLocators(
        bookId: 'book-1',
        canonicalLocator: canonical,
        renderedLocator: rendered,
      );

      expect(selection.selectedText, 'selected text');
      expect(selection.prefix, 'canonical before');
      expect(selection.suffix, 'canonical after');
      expect(selection.startOffsetUtf16, 25);
      expect(selection.renderer, ReaderRendererType.nativeExtension);
      expect(selection.progression, 0.6);
      expect(selection.positionHint, 6);
      expect(selection.totalPositionsHint, 10);
      expect(
        LocatorCodec.decodeRenderedLocator(selection.rendererLocatorJson!),
        rendered,
      );
    });

    test('round-trips every persisted field through LocatorCodec', () {
      final selection = ReaderSelection.create(
        bookId: 'book-2',
        format: BookFormat.txt,
        renderer: ReaderRendererType.textNative,
        selectedText: 'selected text',
        chapterId: 'chapter-5',
        resourceHref: 'text://chapter/chapter-5/offset/5',
        startOffsetUtf16: 5,
        lengthUtf16: 13,
        prefix: 'before',
        suffix: 'after',
        progression: 0.5,
        positionHint: 3,
        totalPositionsHint: 6,
        rendererLocatorJson: '{"position":3}',
      );

      final restored = LocatorCodec.decodeReaderSelection(
        LocatorCodec.encodeReaderSelection(selection),
      );

      expect(restored, selection);
    });
  });

  group('LocatorCodec malformed input', () {
    test('returns null for empty, malformed, and non-object JSON', () {
      final decoders = <Object? Function(String)>[
        LocatorCodec.decodeTextAnchor,
        LocatorCodec.decodeCanonicalLocator,
        LocatorCodec.decodeRenderedLocator,
        LocatorCodec.decodeAnnotationAnchor,
        LocatorCodec.decodeReaderSelection,
      ];

      for (final decode in decoders) {
        expect(decode(''), isNull);
        expect(decode('{not-json'), isNull);
        expect(decode('[]'), isNull);
      }
    });
  });
}
