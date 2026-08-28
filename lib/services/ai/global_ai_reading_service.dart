// 文件说明：管理 AI 书籍预处理任务与持久化摘要。
// 技术要点：SharedPreferences、Path Provider、JSON、文件系统。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/models/book.dart' as legacy;
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/ai_preprocess_task_controller.dart';
import 'package:xxread/services/ai/book_preprocess_service.dart';
import 'package:xxread/services/books/book_text_extraction_service.dart';

class GlobalAIReadingService {
  factory GlobalAIReadingService() => _instance;

  GlobalAIReadingService._();

  /// 测试专用构造：允许子类替换落盘行为。
  @visibleForTesting
  GlobalAIReadingService.forTesting();

  static final GlobalAIReadingService _instance = GlobalAIReadingService._();

  static const String _rootFolder = 'ai_knowledge';

  /// 导入后自动预处理入口：仅在“AI 预处理书籍”开启、AI 已配置、
  /// 格式受支持且尚无摘要时后台执行；失败只记日志，不打断导入。
  Future<void> scheduleImportedBookAnalysis({required legacy.Book book}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(aiPreprocessBooksPrefsKey) != true) return;
      if (!BookTextExtractionService.supports(book)) return;
      final bookId = book.id?.toString() ?? '';
      if (bookId.isEmpty || await hasBookSummary(bookId)) return;
      final settings = await ReaderHttpAIService().loadSettings();
      if (!settings.isConfigured) return;
      debugPrint(
        '[GlobalAI] queueing imported book preprocessing: '
        '${book.title}',
      );
      AiPreprocessTaskController().enqueue(book);
    } catch (error) {
      debugPrint('[GlobalAI] preprocessing failed: $error');
    }
  }

  Future<Map<String, dynamic>?> loadBookMemory(String bookId) async {
    return _readJson(await _bookMemoryFile(bookId));
  }

  /// AI 预处理产物：整本书的 Markdown 摘要，写入 memory.json 的 summary 字段，
  /// 供 AI 页对话复用。
  Future<void> saveBookSummary({
    required String bookId,
    required String summary,
  }) async {
    final memoryFile = await _bookMemoryFile(bookId);
    final memory = await _readJson(memoryFile) ?? <String, dynamic>{};
    await _writeJson(memoryFile, <String, dynamic>{
      ...memory,
      'summary': summary,
      'summaryCreatedAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// 读取预处理摘要；没有则返回 null。
  Future<String?> loadBookSummary(String bookId) async {
    final memory = await loadBookMemory(bookId);
    final summary = memory?['summary'];
    if (summary is! String || summary.trim().isEmpty) return null;
    return summary;
  }

  Future<bool> hasBookSummary(String bookId) async =>
      (await loadBookSummary(bookId)) != null;

  Future<File> _bookMemoryFile(String bookId) async {
    final dir = await _bookFolder(bookId);
    return File(p.join(dir.path, 'memory.json'));
  }

  Future<Directory> _ensureRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, _rootFolder));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> _bookFolder(String bookId) async {
    final root = await _ensureRoot();
    final safeId = _safeFileName(bookId);
    final folder = Directory(p.join(root.path, 'books', safeId));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder;
  }

  String _safeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'unknown_book' : sanitized;
  }

  Future<Map<String, dynamic>?> _readJson(File file) async {
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (error) {
      debugPrint('[GlobalAI] read json failed: ${file.path}, $error');
      return null;
    }
  }

  Future<void> _writeJson(File file, Map<String, dynamic> json) async {
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(json), flush: true);
    } catch (error) {
      debugPrint('[GlobalAI] write json failed: ${file.path}, $error');
    }
  }
}
