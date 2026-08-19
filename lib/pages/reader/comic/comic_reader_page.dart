// 文件说明：本地漫画入口。会话与翻页由 ImageReaderHost 统一承载。
// 解析逻辑见 comic_book_parser.dart；格式能力矩阵见 docs/book-format-support.md。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/comic/image_reader_host.dart';
import 'package:xxread/pages/reader/comic/local_comic_source.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/utils/reader_themes.dart';

class ComicReaderPage extends StatelessWidget {
  const ComicReaderPage({
    super.key,
    required this.book,
    required this.initialTheme,
  });

  final Book book;
  final ReaderThemePalette initialTheme;

  /// 与 [NativeReaderService.openBook] 相同的封面展开转场入口。
  static Future<void> open(
    BuildContext context,
    Book book, {
    BookOpenAnimation? animation,
    LibraryBookOpenAnimation? libraryAnimation,
    LibraryBookOpenAnimationPace animationPace =
        LibraryBookOpenAnimationPace.fast,
    ReaderThemePalette? initialTheme,
    bool waitForReaderClose = true,
  }) async {
    final resolvedInitialTheme =
        initialTheme ?? await ReaderThemes.loadSavedPalette();
    if (!context.mounted) return;
    final route = BookOpenTransition.createRoute<void>(
      ComicReaderPage(book: book, initialTheme: resolvedInitialTheme),
      animation: animation,
      libraryAnimation: libraryAnimation,
      animationPace: animationPace,
      readerBackgroundColor: Colors.black,
      waitForReaderReady: true,
    );
    final navigation = BookOpenTransition.push<void>(context, route);
    if (waitForReaderClose) {
      await navigation;
    } else {
      unawaited(navigation);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImageReaderHost(
      source: LocalComicSource(book: book, theme: initialTheme),
    );
  }
}
