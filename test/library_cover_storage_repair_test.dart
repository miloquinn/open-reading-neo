@Tags(['isolated-process'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/library/library_page.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/core/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first library load restores a cover after sandbox relocation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final documents = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('library_relocated_'),
    ))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => documents.path,
    );
    addTearDown(
      () => tester.runAsync(() async {
        await (await DatabaseService().database).close();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await documents.delete(recursive: true);
      }),
    );
    final cover = File(p.join(documents.path, 'covers', 'custom_1_123.png'));
    final file = File(p.join(documents.path, 'books', 'test.epub'));
    late int bookId;
    await tester.runAsync(() async {
      await cover.parent.create(recursive: true);
      await cover.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('book content');
      final db = await DatabaseService().database;
      bookId = await db.insert(
        'books',
        Book(
          title: 'Relocated Book',
          filePath:
              '/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Documents/books/test.epub',
          format: 'epub',
          coverImagePath:
              '/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Documents/covers/custom_1_123.png',
          currentPage: 3,
          totalPages: 10,
        ).toMap(),
      );
      await db.execute('PRAGMA user_version = 24');
      await db.close();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(),
        ),
      ),
    );
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('Relocated Book').evaluate().isNotEmpty) break;
    }

    expect(find.text('Relocated Book'), findsWidgets);
    final images = tester.widgetList<Image>(find.byType(Image));
    final paths = images.map((image) {
      final provider = image.image;
      final original = provider is ResizeImage
          ? provider.imageProvider
          : provider;
      return original is FileImage ? original.file.path : null;
    });
    expect(
      paths,
      contains(cover.path),
      reason:
          'The first shelf render must use the current sandbox without opening the reader.',
    );
    await tester.runAsync(() async {
      final saved = (await BookDao().getBookById(bookId))!;
      expect(saved.coverImagePath, cover.path);
      expect(saved.filePath, file.path);
      expect(saved.currentPage, 3);
      final stored = (await (await DatabaseService().database).query(
        'books',
        where: 'id = ?',
        whereArgs: [bookId],
      )).single;
      expect(stored['filePath'], 'books/test.epub');
      expect(stored['cover_image_path'], 'covers/custom_1_123.png');
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
