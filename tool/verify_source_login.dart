// Manual live probe; credentials and downloaded sources stay outside the repo.
// SOURCE_FILE=/absolute/source.json SOURCE_LOGIN_VALUES='{"email":"..."}'
// SOURCE_LOGIN_ACTION='login()' SOURCE_LOGIN_ORIGIN=https://books.example
// SOURCE_QUERY='example' flutter test tool/verify_source_login.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_http_transport.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  test('live source login and reading chain', () async {
    final env = Platform.environment;
    final Map<String, dynamic> raw;
    if (env['SOURCE_URL'] case final String url) {
      final analyzer = BookSourceImportAnalyzer();
      try {
        final imported = await analyzer.analyzeUrl(url);
        raw = imported.additionalPreview!.sources.single.raw;
        stdout.writeln('URL import: original source parsed.');
      } finally {
        analyzer.close();
      }
    } else {
      final decoded = jsonDecode(
        await File(env['SOURCE_FILE']!).readAsString(),
      );
      raw = Map<String, dynamic>.from(
        decoded is List ? decoded.first : decoded,
      );
    }
    final source = ReadingSourceConfig.fromJson(
      raw,
    ).toRegisteredSource(enabled: true);
    final values = (jsonDecode(env['SOURCE_LOGIN_VALUES']!) as Map).map(
      (key, value) => MapEntry('$key', '$value'),
    );
    final store = _MemoryStore();
    final transport = SourceHttpTransport(
      requestTimeout: const Duration(seconds: 30),
    );
    final runtime = SourceRuntime(
      transport: transport,
      loginSessionStore: store,
    );
    addTearDown(runtime.close);
    await runtime.login(source, values, action: env['SOURCE_LOGIN_ACTION']);
    final origin = Uri.parse(env['SOURCE_LOGIN_ORIGIN']!);
    if (transport.scriptCookieHeader(source.id, origin).isEmpty) {
      fail('Login did not save a Cookie session.');
    }
    stdout.writeln('Login: cookie session saved (values redacted).');
    final results = await runtime.search(source, env['SOURCE_QUERY'] ?? '西游记');
    expect(results.items, isNotEmpty);
    stdout.writeln('Search: ${results.items.length} books.');
    final book = results.items.first;
    final detail = await runtime.getBook(
      source,
      book.id,
      sourceVariables: book.sourceVariables,
    );
    expect(detail.title, isNotEmpty);
    stdout.writeln('Detail: title parsed, type=${detail.type}.');
    final chapters = await runtime.getChapters(
      source,
      book.id,
      sourceVariables: detail.sourceVariables,
    );
    expect(chapters, isNotEmpty);
    stdout.writeln('Catalog: ${chapters.length} chapters.');
    var textLength = 0;
    final sample = StringBuffer();
    for (final chapter in chapters.take(3)) {
      final content = await runtime.getChapterContent(
        source,
        bookId: book.id,
        chapterId: chapter.id,
        sourceVariables: detail.sourceVariables,
      );
      expect(content.content, isNotEmpty);
      sample.write(content.content);
      textLength += content.content
          .replaceAll(RegExp('<[^>]*>'), '')
          .trim()
          .length;
      stdout.writeln(
        'Chapter ${chapter.title}: ${content.content.length} characters, type=${content.contentType}.',
      );
    }
    expect(
      textLength,
      greaterThan(200),
      reason:
          'Confirm substantial readable text, not just an image or short API notice.',
    );
    if (env['SOURCE_EXPECT_TEXT'] case final String expected) {
      expect(sample.toString(), contains(expected));
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

class _MemoryStore implements SourceLoginSessionStore {
  SourceLoginSession _session = const SourceLoginSession();
  @override
  Future<SourceLoginSession> read(String sourceId) async => _session;
  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    _session = session;
  }

  @override
  Future<void> clear(String sourceId) async {
    _session = const SourceLoginSession();
  }
}
