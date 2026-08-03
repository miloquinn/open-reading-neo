// 文件说明：AI 预处理服务，让 AI 通读整本书并生成 Markdown 摘要知识库。
// 技术要点：章节分块、逐块总结、合并成文、限流退避重试、GlobalAIReadingService 落盘。

import 'package:flutter/foundation.dart';

import '../../models/book.dart';
import '../../reader_core/ai/ai_service.dart';
import '../books/book_text_extraction_service.dart';
import 'ai_request_coordinator.dart';
import 'global_ai_reading_service.dart';

/// “AI 预处理书籍”总开关的持久化键；默认关闭。
const String aiPreprocessBooksPrefsKey = 'reader_ai_preprocess_books_v1';

class BookPreprocessCancelled implements Exception {
  const BookPreprocessCancelled();
}

class BookPreprocessCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class _BookChunk {
  const _BookChunk({required this.label, required this.text});

  final String label;
  final String text;
}

class _BookSummary {
  const _BookSummary({required this.label, required this.text});

  final String label;
  final String text;
}

/// 把整本书分块交给 AI 总结，再合并为一份 Markdown 知识库文档。
///
/// 消耗大量 token：每块一次请求 + 分层归并请求。
/// 相邻请求之间保留间隔，限流/网络类错误按退避重试，
/// 避免背靠背连发触发服务商限流后整个任务直接失败。
class BookPreprocessService {
  BookPreprocessService({
    AIService? ai,
    BookTextExtractionService? extractor,
    GlobalAIReadingService? knowledge,
    AiRequestCoordinator? coordinator,
    Duration? requestGap,
    List<Duration>? retryDelays,
  }) : _ai = ai ?? ReaderHttpAIService(),
       _extractor = extractor ?? const BookTextExtractionService(),
       _knowledge = knowledge ?? GlobalAIReadingService(),
       _coordinator = coordinator ?? AiRequestCoordinator(),
       _requestGap = requestGap ?? defaultRequestGap,
       _retryDelays = retryDelays ?? defaultRetryDelays;

  final AIService _ai;
  final BookTextExtractionService _extractor;
  final GlobalAIReadingService _knowledge;
  final AiRequestCoordinator _coordinator;

  /// 相邻两次 AI 请求之间的最小间隔，缓解按分钟计的限流。
  final Duration _requestGap;

  /// 限流/网络类错误的退避序列；长度即额外重试次数。
  final List<Duration> _retryDelays;

  /// 单次正文请求控制在约 3 千字符内，为系统提示与模型输出预留上下文。
  /// 中文通常接近“一字一 token”，原来的 6000 字符对小上下文模型过于激进。
  static const int chunkChars = 2800;
  static const int maxChunks = 24;

  /// 合并也必须分批；每次最多读取三份已压缩摘要，避免最终一次性塞入
  /// 全部 24 份摘要而超过模型上下文。
  static const int mergeFanIn = 3;
  static const int intermediateSummaryChars = 900;

  static const Duration defaultRequestGap = Duration(milliseconds: 1500);
  static const List<Duration> defaultRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  /// 返回生成的 Markdown 摘要；同时写入该书的本地知识库。
  ///
  /// [onProgress] 以 (已完成请求数, 总请求数) 回调；总数含最终合并请求。
  Future<String> preprocessBook({
    required Book book,
    void Function(int done, int total)? onProgress,
    BookPreprocessCancelToken? cancelToken,
  }) async {
    final chapters = await _extractor.extractChapters(book);
    final chunks = _buildChunks(chapters);
    final sampled = _sampleChunks(chunks);
    final total = sampled.length + _mergeRequestCount(sampled.length);
    var done = 0;
    onProgress?.call(0, total);

    final bookId = book.id?.toString() ?? '';
    Future<String> sendRequest(String prompt, String chapterId) async {
      _throwIfCancelled(cancelToken);
      if (done > 0) {
        await _cancellableDelay(_requestGap, cancelToken);
      }
      final answer = await _chatWithRetry(
        history: [AIChatMessage(role: 'user', content: prompt)],
        meta: AIRequestMeta(bookId: bookId, chapterId: chapterId),
        cancelToken: cancelToken,
      );
      done += 1;
      onProgress?.call(done, total);
      return answer.trim();
    }

    final partSummaries = <_BookSummary>[];
    for (var index = 0; index < sampled.length; index++) {
      _throwIfCancelled(cancelToken);
      final chunk = sampled[index];
      final answer = await sendRequest(
        '下面是书籍《${book.title}》的一段正文（${chunk.label}）。'
        '请按原文顺序提炼核心内容、出场人物/概念、关键情节与因果关系。'
        '控制在 $intermediateSummaryChars 字以内，直接输出摘要，不要客套话。'
        '\n\n${chunk.text}',
        chunk.label,
      );
      partSummaries.add(
        _BookSummary(label: chunk.label, text: _limitSummary(answer)),
      );
    }

    // 多层归并：24 份摘要不会再直接进入一次最终请求，而是按 3 份一组
    // 逐层压缩，直到最终请求最多只读取三份中间摘要。
    var mergeLevel = 1;
    var summaries = partSummaries;
    while (summaries.length > mergeFanIn) {
      final merged = <_BookSummary>[];
      for (var start = 0; start < summaries.length; start += mergeFanIn) {
        final end = (start + mergeFanIn).clamp(0, summaries.length);
        final group = summaries.sublist(start, end);
        final label = _summaryRangeLabel(group);
        final prompt = StringBuffer()
          ..writeln('以下是书籍《${book.title}》连续部分的摘要。')
          ..writeln(
            '请按原书顺序合并为一份中间摘要，保留人物/概念、关键情节、'
            '因果、转折和章节范围，控制在 $intermediateSummaryChars 字以内。',
          )
          ..writeln()
          ..writeln(_formatSummaries(group));
        final answer = await sendRequest(
          prompt.toString(),
          'preprocess-merge-$mergeLevel-${merged.length + 1}',
        );
        merged.add(_BookSummary(label: label, text: _limitSummary(answer)));
      }
      summaries = merged;
      mergeLevel += 1;
    }

    _throwIfCancelled(cancelToken);
    final omitted = chunks.length - sampled.length;
    final mergePrompt = StringBuffer()
      ..writeln(
        '以下是书籍《${book.title}》（作者：${book.author}）按顺序归并后的摘要。'
        '请把它们整理成一份结构化的 Markdown 知识库文档，包含：'
        '一段总体梗概、主要人物或核心概念列表、按顺序的分章要点。'
        '直接输出 Markdown 正文，以“# ${book.title}”开头。',
      );
    if (omitted > 0) {
      mergePrompt.writeln('（注意：因篇幅限制，另有 $omitted 段正文未纳入总结，请在文末注明。）');
    }
    mergePrompt
      ..writeln()
      ..writeln(_formatSummaries(summaries));

    final markdown = await sendRequest(
      mergePrompt.toString(),
      'preprocess-merge',
    );

    final document = markdown;
    await _knowledge.saveBookSummary(bookId: bookId, summary: document);
    return document;
  }

  int _mergeRequestCount(int summaryCount) {
    var current = summaryCount;
    var requests = 1; // 最终 Markdown 整理请求。
    while (current > mergeFanIn) {
      current = (current + mergeFanIn - 1) ~/ mergeFanIn;
      requests += current;
    }
    return requests;
  }

  String _limitSummary(String text) {
    final compact = text.trim();
    if (compact.length <= intermediateSummaryChars) return compact;
    return '${compact.substring(0, intermediateSummaryChars)}…';
  }

  String _summaryRangeLabel(List<_BookSummary> summaries) {
    if (summaries.isEmpty) return '未命名部分';
    if (summaries.length == 1) return summaries.first.label;
    return '${summaries.first.label} — ${summaries.last.label}';
  }

  String _formatSummaries(List<_BookSummary> summaries) => summaries
      .map((summary) => '### ${summary.label}\n${summary.text}')
      .join('\n\n');

  /// 发出一次预处理请求：每次尝试前先让行交互式对话；
  /// 限流/网络类错误按 [_retryDelays] 退避重试，其余错误立即失败。
  Future<String> _chatWithRetry({
    required List<AIChatMessage> history,
    required AIRequestMeta meta,
    BookPreprocessCancelToken? cancelToken,
  }) async {
    var attempt = 0;
    while (true) {
      // 交互式对话优先：等对话请求结束再发，避免挤占服务商并发额度。
      await _coordinator.waitUntilInteractiveIdle();
      _throwIfCancelled(cancelToken);
      try {
        return await _ai.chat(history: history, pageText: '', meta: meta);
      } on AIServiceException catch (error) {
        if (!_isRetryable(error) || attempt >= _retryDelays.length) {
          rethrow;
        }
        final delay = _retryDelays[attempt];
        attempt += 1;
        debugPrint(
          '[Preprocess] ${meta.chapterId} 请求失败（${error.code}'
          '${error.status?.isNotEmpty == true ? '/${error.status}' : ''}），'
          '${delay.inSeconds}s 后第 $attempt 次重试',
        );
        await _cancellableDelay(delay, cancelToken);
      }
    }
  }

  /// 限流（429/529）、服务端故障（5xx）与网络传输失败值得重试；
  /// 配置类错误（Key 无效、模型不匹配等）重试无意义，立即失败。
  bool _isRetryable(AIServiceException error) {
    const retryableStatuses = {'408', '429', '500', '502', '503', '504', '529'};
    if (retryableStatuses.contains(error.status)) return true;
    const retryableCodes = {
      'network_request_failed',
      'failed_read_body',
      'empty_response_error',
      'empty_response',
    };
    return retryableCodes.contains(error.code);
  }

  void _throwIfCancelled(BookPreprocessCancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw const BookPreprocessCancelled();
    }
  }

  /// 分片睡眠，让退避等待期间的取消也能即时生效。
  Future<void> _cancellableDelay(
    Duration duration,
    BookPreprocessCancelToken? cancelToken,
  ) async {
    const slice = Duration(milliseconds: 250);
    var remaining = duration;
    while (remaining > Duration.zero) {
      _throwIfCancelled(cancelToken);
      final step = remaining < slice ? remaining : slice;
      await Future<void>.delayed(step);
      remaining -= step;
    }
    _throwIfCancelled(cancelToken);
  }

  List<_BookChunk> _buildChunks(List<BookChapterText> chapters) {
    final chunks = <_BookChunk>[];
    final buffer = StringBuffer();
    String? bufferLabel;

    void flush() {
      if (buffer.isEmpty || bufferLabel == null) return;
      chunks.add(_BookChunk(label: bufferLabel!, text: buffer.toString()));
      buffer.clear();
      bufferLabel = null;
    }

    for (final chapter in chapters) {
      final text = chapter.text.trim();
      if (text.isEmpty) continue;
      if (text.length >= chunkChars) {
        flush();
        final parts = _splitLongText(text);
        for (var index = 0; index < parts.length; index++) {
          chunks.add(
            _BookChunk(
              label: index == 0
                  ? chapter.title
                  : '${chapter.title}（${index + 1}）',
              text: parts[index],
            ),
          );
        }
        continue;
      }
      if (buffer.length + text.length > chunkChars) flush();
      if (buffer.isEmpty) {
        bufferLabel = chapter.title;
      } else {
        buffer.writeln();
      }
      buffer.writeln(text);
    }
    flush();
    return chunks;
  }

  /// 长章节优先在段落或句末切开；找不到自然边界时才按字符上限硬切。
  /// 这样每个请求既有明确的上下文上限，也尽量不把一句话截成两半。
  List<String> _splitLongText(String text) {
    final parts = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + chunkChars).clamp(0, text.length);
      if (end < text.length) {
        final earliest = start + (chunkChars * 3 ~/ 4);
        end = _naturalSplitPosition(text, earliest, end);
        if (_splitsSurrogatePair(text, end)) end -= 1;
      }
      final part = text.substring(start, end).trim();
      if (part.isNotEmpty) parts.add(part);
      start = end;
    }
    return parts;
  }

  int _naturalSplitPosition(String text, int earliest, int fallback) {
    const boundaries = {'\n', '。', '！', '？', '；', '.', '!', '?', ';'};
    for (var index = fallback - 1; index >= earliest; index--) {
      if (boundaries.contains(text[index])) return index + 1;
    }
    return fallback;
  }

  bool _splitsSurrogatePair(String text, int position) {
    if (position <= 0 || position >= text.length) return false;
    final before = text.codeUnitAt(position - 1);
    final after = text.codeUnitAt(position);
    return before >= 0xD800 &&
        before <= 0xDBFF &&
        after >= 0xDC00 &&
        after <= 0xDFFF;
  }

  /// 超长书籍均匀抽样，控制 token 消耗上限。
  List<_BookChunk> _sampleChunks(List<_BookChunk> chunks) {
    if (chunks.length <= maxChunks) return chunks;
    final sampled = <_BookChunk>[];
    for (var index = 0; index < maxChunks; index++) {
      final position = (index * (chunks.length - 1) / (maxChunks - 1)).round();
      sampled.add(chunks[position]);
    }
    return sampled;
  }
}
