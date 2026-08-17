import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

bool get isReaderAloudPlatformSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

enum ReaderAloudPlaybackState { stopped, loading, playing, paused, error }

enum ReaderAloudControl {
  previous,
  play,
  pause,
  playPause,
  next,
  refresh,
  stop,
}

class ReaderAloudPosition {
  const ReaderAloudPosition({required this.chapterIndex, required this.offset});

  final int chapterIndex;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is ReaderAloudPosition &&
      other.chapterIndex == chapterIndex &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(chapterIndex, offset);
}

class ReaderAloudChapter {
  const ReaderAloudChapter({
    required this.index,
    required this.id,
    required this.title,
    required this.text,
  });

  final int index;
  final String id;
  final String title;
  final String text;
}

class ReaderAloudSegment {
  const ReaderAloudSegment({
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.startOffset,
    required this.endOffset,
    required this.text,
  });

  final int chapterIndex;
  final String chapterId;
  final String chapterTitle;
  final int startOffset;
  final int endOffset;
  final String text;
}

@immutable
class ReaderAloudHighlight {
  const ReaderAloudHighlight({
    required this.chapterIndex,
    required this.chapterId,
    required this.startOffset,
    required this.endOffset,
  });

  final int chapterIndex;
  final String chapterId;
  final int startOffset;
  final int endOffset;

  bool matches({required int chapterIndex, required String chapterId}) =>
      this.chapterIndex == chapterIndex && this.chapterId == chapterId;

  @override
  bool operator ==(Object other) =>
      other is ReaderAloudHighlight &&
      other.chapterIndex == chapterIndex &&
      other.chapterId == chapterId &&
      other.startOffset == startOffset &&
      other.endOffset == endOffset;

  @override
  int get hashCode =>
      Object.hash(chapterIndex, chapterId, startOffset, endOffset);
}

abstract interface class ReaderAloudEngine implements Listenable {
  bool get isPlaying;
  bool get isPaused;
  int get currentPosition;

  Future<void> speak(String text);
  Future<void> pause();
  Future<void> stop();
}

abstract interface class ReaderAloudAdjustableEngine
    implements ReaderAloudEngine {
  double get speechRate;
  double get speechVolume;
}

/// Marks an engine that can reliably report progress through a longer
/// utterance. The controller uses this to send adjacent sentences in one TTS
/// request, avoiding the audible gap caused by starting a new request after
/// every sentence.
abstract interface class ReaderAloudContinuousEngine
    implements ReaderAloudEngine {
  bool get supportsContinuousText;
}

/// An engine that can enqueue several short utterances without an audible
/// pause while still reporting exactly which utterance has started.
///
/// Android system TTS engines are much more reliable at reporting sentence
/// boundaries this way than at reporting ranges inside one long utterance.
abstract interface class ReaderAloudQueuedEngine implements ReaderAloudEngine {
  bool get supportsQueuedText;

  Future<void> speakQueued(
    List<String> texts, {
    required ValueChanged<int> onTextStarted,
  });
}

abstract interface class ReaderAloudSource {
  String get bookTitle;
  int get chapterCount;

  Future<ReaderAloudPosition> currentPosition();
  Future<ReaderAloudChapter?> loadChapter(int index);
  Future<void> revealPosition(ReaderAloudPosition position);
  Future<void> persistPosition(ReaderAloudPosition position);
}

class CallbackReaderAloudSource implements ReaderAloudSource {
  factory CallbackReaderAloudSource({
    required String bookTitle,
    required int Function() chapterCount,
    required Future<ReaderAloudPosition> Function() currentPosition,
    required Future<ReaderAloudChapter?> Function(int index) loadChapter,
    required Future<void> Function(ReaderAloudPosition position) revealPosition,
    required Future<void> Function(ReaderAloudPosition position)
    persistPosition,
  }) => CallbackReaderAloudSource._(
    bookTitle,
    chapterCount,
    currentPosition,
    loadChapter,
    revealPosition,
    persistPosition,
  );

  const CallbackReaderAloudSource._(
    this.bookTitle,
    this._chapterCount,
    this._currentPosition,
    this._loadChapter,
    this._revealPosition,
    this._persistPosition,
  );

  @override
  final String bookTitle;
  final int Function() _chapterCount;
  final Future<ReaderAloudPosition> Function() _currentPosition;
  final Future<ReaderAloudChapter?> Function(int index) _loadChapter;
  final Future<void> Function(ReaderAloudPosition position) _revealPosition;
  final Future<void> Function(ReaderAloudPosition position) _persistPosition;

  @override
  int get chapterCount => _chapterCount();

  @override
  Future<ReaderAloudPosition> currentPosition() => _currentPosition();

  @override
  Future<ReaderAloudChapter?> loadChapter(int index) => _loadChapter(index);

  @override
  Future<void> persistPosition(ReaderAloudPosition position) =>
      _persistPosition(position);

  @override
  Future<void> revealPosition(ReaderAloudPosition position) =>
      _revealPosition(position);
}

class ReaderAloudNotificationData {
  const ReaderAloudNotificationData({
    required this.bookTitle,
    required this.chapterTitle,
    required this.state,
    required this.chapterIndex,
    required this.chapterCount,
    required this.progress,
  });

  final String bookTitle;
  final String chapterTitle;
  final ReaderAloudPlaybackState state;
  final int chapterIndex;
  final int chapterCount;
  final double progress;
}

abstract interface class ReaderAloudNotificationSink {
  Stream<ReaderAloudControl> get controls;

  Future<void> show(ReaderAloudNotificationData data);
  Future<void> stop();
}

class NoopReaderAloudNotificationSink implements ReaderAloudNotificationSink {
  const NoopReaderAloudNotificationSink();

  @override
  Stream<ReaderAloudControl> get controls => const Stream.empty();

  @override
  Future<void> show(ReaderAloudNotificationData data) async {}

  @override
  Future<void> stop() async {}
}

typedef ReaderAloudSegmentBuilder =
    List<ReaderAloudSegment> Function(ReaderAloudChapter chapter);

class ReaderAloudSegmenter {
  const ReaderAloudSegmenter._();

  static const String _boundaries = '。！？!?；;：:\n';

  static List<ReaderAloudSegment> split({
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
    required String text,
    int maxCharacters = 320,
    int minimumCharacters = 1,
  }) {
    if (text.trim().isEmpty) return const [];
    final safeMax = math.max(1, maxCharacters);
    final safeMinimum = minimumCharacters.clamp(1, safeMax);
    final segments = <ReaderAloudSegment>[];
    var cursor = 0;

    while (cursor < text.length) {
      while (cursor < text.length && _isWhitespace(text.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor >= text.length) break;

      final start = cursor;
      final hardEnd = math.min(text.length, start + safeMax);
      var end = -1;
      for (var index = start; index < hardEnd; index++) {
        final character = text[index];
        if (_boundaries.contains(character) &&
            index + 1 - start >= safeMinimum) {
          end = index + 1;
          break;
        }
      }
      if (end < 0) {
        end = hardEnd;
        if (hardEnd < text.length) {
          for (var index = hardEnd - 1; index > start; index--) {
            if (_isWhitespace(text.codeUnitAt(index))) {
              end = index;
              break;
            }
          }
        }
      }
      if (end > start &&
          end < text.length &&
          _isHighSurrogate(text.codeUnitAt(end - 1))) {
        end--;
      }
      if (end <= start) end = math.min(text.length, start + 1);

      var trimmedEnd = end;
      while (trimmedEnd > start &&
          _isWhitespace(text.codeUnitAt(trimmedEnd - 1))) {
        trimmedEnd--;
      }
      if (trimmedEnd > start) {
        segments.add(
          ReaderAloudSegment(
            chapterIndex: chapterIndex,
            chapterId: chapterId,
            chapterTitle: chapterTitle,
            startOffset: start,
            endOffset: trimmedEnd,
            text: text.substring(start, trimmedEnd),
          ),
        );
      }
      cursor = end;
    }

    return segments;
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D ||
      codeUnit == 0x3000;

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
}

class ReaderAloudController extends ChangeNotifier {
  static const int _continuousBatchMaxCharacters = 1800;

  ReaderAloudController({
    required this.engine,
    required this.source,
    this.notificationSink = const NoopReaderAloudNotificationSink(),
    ReaderAloudSegmentBuilder? segmenter,
  }) : _segmenter =
           segmenter ??
           ((chapter) => ReaderAloudSegmenter.split(
             chapterIndex: chapter.index,
             chapterId: chapter.id,
             chapterTitle: chapter.title,
             text: chapter.text,
           )) {
    engine.addListener(_handleEngineChanged);
    _controlSubscription = notificationSink.controls.listen(_handleControl);
  }

  final ReaderAloudEngine engine;
  final ReaderAloudSource source;
  final ReaderAloudNotificationSink notificationSink;
  final ReaderAloudSegmentBuilder _segmenter;

  StreamSubscription<ReaderAloudControl>? _controlSubscription;
  Timer? _notificationTimer;
  Timer? _progressSaveTimer;
  Timer? _sleepTimer;
  ReaderAloudPlaybackState _state = ReaderAloudPlaybackState.stopped;
  ReaderAloudChapter? _currentChapter;
  List<ReaderAloudSegment> _segments = const [];
  int _segmentIndex = 0;
  int _utteranceBaseOffset = 0;
  int? _continuousUtteranceStartOffset;
  int? _continuousUtteranceEndSegmentIndex;
  int _resumeOffset = 0;
  int _generation = 0;
  bool _disposed = false;
  Object? _lastError;
  Duration? _sleepDuration;
  DateTime? _sleepDeadline;

  ReaderAloudPlaybackState get state => _state;
  ReaderAloudChapter? get currentChapter => _currentChapter;
  ReaderAloudSegment? get currentSegment =>
      _segments.isEmpty ? null : _segments[_segmentIndex];
  ReaderAloudHighlight? get highlight {
    if (!isActive) return null;
    final segment = currentSegment;
    if (segment == null) return null;
    return ReaderAloudHighlight(
      chapterIndex: segment.chapterIndex,
      chapterId: segment.chapterId,
      startOffset: segment.startOffset,
      // A sentence is the smallest stable unit across system and cloud TTS.
      // It remains visible for the full utterance even when a platform does
      // not expose word-boundary callbacks.
      endOffset: segment.endOffset,
    );
  }

  Object? get lastError => _lastError;
  Duration? get sleepDuration => _sleepDuration;
  Duration? get sleepRemaining {
    final deadline = _sleepDeadline;
    if (deadline == null) return null;
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isActive =>
      _state == ReaderAloudPlaybackState.loading ||
      _state == ReaderAloudPlaybackState.playing ||
      _state == ReaderAloudPlaybackState.paused;

  int get currentOffset {
    final segment = currentSegment;
    if (segment == null) return 0;
    final continuousStart = _continuousUtteranceStartOffset;
    if (_state == ReaderAloudPlaybackState.playing && continuousStart != null) {
      return (continuousStart + engine.currentPosition).clamp(
        segment.startOffset,
        segment.endOffset,
      );
    }
    final relative = _state == ReaderAloudPlaybackState.playing
        ? _utteranceBaseOffset + engine.currentPosition
        : _resumeOffset;
    return (segment.startOffset + relative).clamp(
      segment.startOffset,
      segment.endOffset,
    );
  }

  double get chapterProgress {
    final chapter = _currentChapter;
    if (chapter == null || chapter.text.isEmpty) return 0;
    return (currentOffset / chapter.text.length).clamp(0.0, 1.0);
  }

  Future<void> start() async {
    if (_disposed) return;
    if (_state == ReaderAloudPlaybackState.paused) {
      await resume();
      return;
    }
    final generation = ++_generation;
    _setState(ReaderAloudPlaybackState.loading);
    _lastError = null;
    await engine.stop();
    try {
      final position = await source.currentPosition();
      if (!_isCurrent(generation)) return;
      final loaded = await _loadChapterAt(
        position.chapterIndex,
        startOffset: position.offset,
      );
      if (!loaded || !_isCurrent(generation)) {
        if (_isCurrent(generation)) {
          throw StateError('没有可朗读的正文');
        }
        return;
      }
      _setState(ReaderAloudPlaybackState.playing);
      unawaited(_playCurrent(generation));
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> pause() async {
    if (_state != ReaderAloudPlaybackState.playing) return;
    _captureResumeOffset();
    final generation = ++_generation;
    _setState(ReaderAloudPlaybackState.paused);
    try {
      await engine.pause();
    } catch (error) {
      _fail(error, generation);
      return;
    }
    await _persistCurrentPosition();
    await _showNotification();
  }

  Future<void> resume() async {
    if (_state != ReaderAloudPlaybackState.paused || currentSegment == null) {
      return;
    }
    final generation = ++_generation;
    _setState(ReaderAloudPlaybackState.playing);
    unawaited(_playCurrent(generation));
  }

  /// Restarts the active sentence from the engine's current UTF-16 position.
  ///
  /// Platform TTS engines generally apply rate, pitch and voice changes only
  /// to the next utterance. Restarting the remaining text makes those changes
  /// audible immediately without replaying the beginning of the sentence.
  Future<void> refreshPlayback() async {
    if (_disposed ||
        _state != ReaderAloudPlaybackState.playing ||
        currentSegment == null) {
      return;
    }
    _captureResumeOffset();
    final generation = ++_generation;
    try {
      await engine.stop();
    } catch (error) {
      _fail(error, generation);
      return;
    }
    if (!_isCurrent(generation) || _state != ReaderAloudPlaybackState.playing) {
      return;
    }
    notifyListeners();
    unawaited(_playCurrent(generation));
  }

  Future<void> previous() => _moveBy(-1);

  Future<void> next() => _moveBy(1);

  Future<void> stop() async {
    if (_state == ReaderAloudPlaybackState.playing) {
      _captureResumeOffset(keepFurthest: true);
    }
    _clearContinuousUtterance();
    ++_generation;
    _notificationTimer?.cancel();
    _progressSaveTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDuration = null;
    _sleepDeadline = null;
    if (!_disposed) {
      _setState(ReaderAloudPlaybackState.stopped);
    }
    await engine.stop();
    await _persistCurrentPosition();
    await _stopNotification();
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    final normalized = duration != null && duration > Duration.zero
        ? duration
        : null;
    _sleepDuration = normalized;
    _sleepDeadline = normalized == null ? null : DateTime.now().add(normalized);
    if (normalized != null) {
      _sleepTimer = Timer(normalized, () => unawaited(stop()));
    }
    notifyListeners();
  }

  Future<void> _moveBy(int delta) async {
    if (_disposed) return;
    if (currentSegment == null) {
      await start();
      return;
    }
    final generation = ++_generation;
    _clearContinuousUtterance();
    await engine.stop();
    if (!_isCurrent(generation)) return;
    bool moved;
    try {
      moved = delta < 0 ? await _movePrevious() : await _moveNext();
    } catch (error) {
      _fail(error, generation);
      return;
    }
    if (!moved || !_isCurrent(generation)) {
      if (delta > 0) {
        _resumeOffset = currentSegment?.text.length ?? _resumeOffset;
        await stop();
      } else if (_isCurrent(generation)) {
        _resumeOffset = 0;
        _setState(ReaderAloudPlaybackState.playing);
        unawaited(_playCurrent(generation));
      }
      return;
    }
    _resumeOffset = 0;
    _setState(ReaderAloudPlaybackState.playing);
    unawaited(_playCurrent(generation));
  }

  Future<bool> _movePrevious() async {
    if (_segmentIndex > 0) {
      _segmentIndex--;
      notifyListeners();
      return true;
    }
    final chapterIndex = (_currentChapter?.index ?? 0) - 1;
    if (chapterIndex < 0) return false;
    final loaded = await _loadChapterAt(chapterIndex, startFromEnd: true);
    return loaded;
  }

  Future<bool> _moveNext() async {
    if (_segmentIndex + 1 < _segments.length) {
      _segmentIndex++;
      notifyListeners();
      return true;
    }
    final chapterIndex = (_currentChapter?.index ?? -1) + 1;
    if (chapterIndex >= source.chapterCount) return false;
    return _loadChapterAt(chapterIndex);
  }

  Future<bool> _loadChapterAt(
    int chapterIndex, {
    int startOffset = 0,
    bool startFromEnd = false,
  }) async {
    var index = chapterIndex;
    while (index >= 0 && index < source.chapterCount) {
      final chapter = await source.loadChapter(index);
      if (chapter == null) return false;
      final segments = _segmenter(chapter);
      if (segments.isNotEmpty) {
        _clearContinuousUtterance();
        _currentChapter = chapter;
        _segments = segments;
        if (startFromEnd) {
          _segmentIndex = segments.length - 1;
        } else {
          final matching = segments.indexWhere(
            (segment) => startOffset < segment.endOffset,
          );
          _segmentIndex = matching < 0 ? segments.length - 1 : matching;
        }
        final segment = _segments[_segmentIndex];
        _resumeOffset = startFromEnd
            ? 0
            : (startOffset - segment.startOffset).clamp(0, segment.text.length);
        notifyListeners();
        return true;
      }
      index += startFromEnd ? -1 : 1;
      startOffset = 0;
    }
    return false;
  }

  Future<void> _playCurrent(int generation) async {
    while (_isCurrent(generation) &&
        _state == ReaderAloudPlaybackState.playing) {
      final segment = currentSegment;
      if (segment == null) return;
      final startAt = _resumeOffset.clamp(0, segment.text.length);
      final queued = _supportsQueuedText;
      final continuous = !queued && _supportsContinuousText;
      final firstSegmentIndex = _segmentIndex;
      var utteranceEndSegmentIndex = _segmentIndex;
      var utteranceStartOffset = segment.startOffset + startAt;
      var utteranceEndOffset = segment.endOffset;
      if (queued || continuous) {
        while (utteranceEndSegmentIndex + 1 < _segments.length) {
          final next = _segments[utteranceEndSegmentIndex + 1];
          if (next.chapterId != segment.chapterId ||
              next.endOffset - utteranceStartOffset >
                  _continuousBatchMaxCharacters) {
            break;
          }
          utteranceEndSegmentIndex++;
          utteranceEndOffset = next.endOffset;
        }
      }
      final chapter = _currentChapter;
      final queuedTexts = queued
          ? <String>[
              segment.text.substring(startAt),
              for (
                var index = firstSegmentIndex + 1;
                index <= utteranceEndSegmentIndex;
                index++
              )
                _segments[index].text,
            ]
          : const <String>[];
      final spokenText = queued
          ? queuedTexts.join()
          : continuous && chapter != null
          ? chapter.text.substring(utteranceStartOffset, utteranceEndOffset)
          : segment.text.substring(startAt);
      if (spokenText.trim().isEmpty) {
        bool moved;
        try {
          moved = await _moveNext();
        } catch (error) {
          _fail(error, generation);
          return;
        }
        if (!moved) {
          _resumeOffset = segment.text.length;
          await stop();
          return;
        }
        _resumeOffset = 0;
        continue;
      }

      _utteranceBaseOffset = startAt;
      if (continuous) {
        _continuousUtteranceStartOffset = utteranceStartOffset;
        _continuousUtteranceEndSegmentIndex = utteranceEndSegmentIndex;
      } else {
        _clearContinuousUtterance();
      }
      try {
        await source.revealPosition(
          ReaderAloudPosition(
            chapterIndex: segment.chapterIndex,
            offset: segment.startOffset + startAt,
          ),
        );
      } catch (error) {
        debugPrint('reveal reader aloud position failed: $error');
      }
      if (!_isCurrent(generation)) return;
      await _persistCurrentPosition();
      await _showNotification();

      try {
        if (queued) {
          await (engine as ReaderAloudQueuedEngine).speakQueued(
            queuedTexts,
            onTextStarted: (relativeIndex) {
              if (!_isCurrent(generation) ||
                  _state != ReaderAloudPlaybackState.playing) {
                return;
              }
              final nextIndex = firstSegmentIndex + relativeIndex;
              if (relativeIndex < 0 ||
                  nextIndex < firstSegmentIndex ||
                  nextIndex > utteranceEndSegmentIndex ||
                  nextIndex >= _segments.length) {
                return;
              }
              _segmentIndex = nextIndex;
              _utteranceBaseOffset = relativeIndex == 0 ? startAt : 0;
              _resumeOffset = _utteranceBaseOffset;
              final startedSegment = _segments[nextIndex];
              notifyListeners();
              unawaited(
                source
                    .revealPosition(
                      ReaderAloudPosition(
                        chapterIndex: startedSegment.chapterIndex,
                        offset:
                            startedSegment.startOffset + _utteranceBaseOffset,
                      ),
                    )
                    .catchError((Object error) {
                      debugPrint('reveal reader aloud position failed: $error');
                    }),
              );
            },
          );
        } else {
          await engine.speak(spokenText);
        }
      } catch (error) {
        _fail(error, generation);
        return;
      }
      if (!_isCurrent(generation) ||
          _state != ReaderAloudPlaybackState.playing) {
        return;
      }

      final completedSegmentIndex = queued
          ? utteranceEndSegmentIndex
          : _continuousUtteranceEndSegmentIndex ?? _segmentIndex;
      _segmentIndex = completedSegmentIndex;
      final completedSegment = currentSegment!;
      _clearContinuousUtterance();
      _resumeOffset = completedSegment.text.length;
      await _persistPosition(
        ReaderAloudPosition(
          chapterIndex: completedSegment.chapterIndex,
          offset: completedSegment.endOffset,
        ),
      );
      bool moved;
      try {
        moved = await _moveNext();
      } catch (error) {
        _fail(error, generation);
        return;
      }
      if (!moved) {
        await stop();
        return;
      }
      _resumeOffset = 0;
    }
  }

  void _handleEngineChanged() {
    if (_disposed || _state != ReaderAloudPlaybackState.playing) return;
    if (engine.isPlaying) {
      _syncContinuousSegmentFromEngine();
    }
    notifyListeners();
    _notificationTimer ??= Timer(const Duration(milliseconds: 450), () {
      _notificationTimer = null;
      unawaited(_showNotification());
    });
    _progressSaveTimer ??= Timer(const Duration(seconds: 2), () {
      _progressSaveTimer = null;
      unawaited(_persistCurrentPosition());
    });
  }

  bool get _supportsContinuousText =>
      engine is ReaderAloudContinuousEngine &&
      (engine as ReaderAloudContinuousEngine).supportsContinuousText;

  bool get _supportsQueuedText =>
      engine is ReaderAloudQueuedEngine &&
      (engine as ReaderAloudQueuedEngine).supportsQueuedText;

  void _captureResumeOffset({bool keepFurthest = false}) {
    var segment = currentSegment;
    if (segment == null) return;

    final continuousStart = _continuousUtteranceStartOffset;
    if (continuousStart != null) {
      final absoluteOffset = continuousStart + engine.currentPosition;
      _syncContinuousSegmentAt(absoluteOffset);
      segment = currentSegment;
      if (segment == null) return;
      final relative = (absoluteOffset - segment.startOffset).clamp(
        0,
        segment.text.length,
      );
      _resumeOffset = keepFurthest
          ? math.max(_resumeOffset, relative)
          : relative;
      _clearContinuousUtterance();
      return;
    }

    final relative = (_utteranceBaseOffset + engine.currentPosition).clamp(
      0,
      segment.text.length,
    );
    _resumeOffset = keepFurthest ? math.max(_resumeOffset, relative) : relative;
  }

  void _syncContinuousSegmentFromEngine() {
    final start = _continuousUtteranceStartOffset;
    if (start == null) return;
    _syncContinuousSegmentAt(start + engine.currentPosition);
  }

  void _syncContinuousSegmentAt(int absoluteOffset) {
    final endIndex = _continuousUtteranceEndSegmentIndex;
    if (endIndex == null || _segments.isEmpty) return;
    final firstIndex = _segmentIndex.clamp(0, endIndex);
    var matchingIndex = endIndex;
    for (var index = firstIndex; index <= endIndex; index++) {
      if (absoluteOffset < _segments[index].endOffset) {
        matchingIndex = index;
        break;
      }
    }
    if (matchingIndex == _segmentIndex) return;
    _segmentIndex = matchingIndex;
    final segment = _segments[matchingIndex];
    unawaited(
      source
          .revealPosition(
            ReaderAloudPosition(
              chapterIndex: segment.chapterIndex,
              offset: segment.startOffset,
            ),
          )
          .catchError((Object error) {
            debugPrint('reveal reader aloud position failed: $error');
          }),
    );
  }

  void _clearContinuousUtterance() {
    _continuousUtteranceStartOffset = null;
    _continuousUtteranceEndSegmentIndex = null;
  }

  Future<void> _persistCurrentPosition() async {
    final segment = currentSegment;
    if (segment == null) return;
    await _persistPosition(
      ReaderAloudPosition(
        chapterIndex: segment.chapterIndex,
        offset: currentOffset,
      ),
    );
  }

  Future<void> _persistPosition(ReaderAloudPosition position) async {
    try {
      await source.persistPosition(position);
    } catch (error) {
      debugPrint('persist reader aloud position failed: $error');
    }
  }

  Future<void> _showNotification() async {
    final chapter = _currentChapter;
    if (chapter == null || _state == ReaderAloudPlaybackState.stopped) return;
    try {
      await notificationSink.show(
        ReaderAloudNotificationData(
          bookTitle: source.bookTitle,
          chapterTitle: chapter.title,
          state: _state,
          chapterIndex: chapter.index,
          chapterCount: source.chapterCount,
          progress: chapterProgress,
        ),
      );
    } catch (error) {
      debugPrint('show reader aloud notification failed: $error');
    }
  }

  Future<void> _stopNotification() async {
    try {
      await notificationSink.stop();
    } catch (error) {
      debugPrint('stop reader aloud notification failed: $error');
    }
  }

  void _handleControl(ReaderAloudControl control) {
    switch (control) {
      case ReaderAloudControl.previous:
        unawaited(previous());
      case ReaderAloudControl.play:
        if (_state == ReaderAloudPlaybackState.paused) {
          unawaited(resume());
        } else if (_state == ReaderAloudPlaybackState.stopped ||
            _state == ReaderAloudPlaybackState.error) {
          unawaited(start());
        }
      case ReaderAloudControl.pause:
        if (_state == ReaderAloudPlaybackState.playing) {
          unawaited(pause());
        }
      case ReaderAloudControl.playPause:
        if (_state == ReaderAloudPlaybackState.playing) {
          unawaited(pause());
        } else if (_state == ReaderAloudPlaybackState.paused) {
          unawaited(resume());
        } else {
          unawaited(start());
        }
      case ReaderAloudControl.next:
        unawaited(next());
      case ReaderAloudControl.refresh:
        if (_state == ReaderAloudPlaybackState.playing) {
          unawaited(refreshPlayback());
        }
      case ReaderAloudControl.stop:
        unawaited(stop());
    }
  }

  void _fail(Object error, int generation) {
    if (!_isCurrent(generation)) return;
    _lastError = error;
    _setState(ReaderAloudPlaybackState.error);
    unawaited(engine.stop());
    unawaited(_stopNotification());
  }

  void _setState(ReaderAloudPlaybackState value) {
    if (_state == value || _disposed) return;
    _state = value;
    notifyListeners();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _notificationTimer?.cancel();
    _progressSaveTimer?.cancel();
    _sleepTimer?.cancel();
    engine.removeListener(_handleEngineChanged);
    unawaited(_controlSubscription?.cancel());
    unawaited(_persistCurrentPosition());
    unawaited(engine.stop());
    unawaited(_stopNotification());
    super.dispose();
  }
}
