import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFlutterTts tts;
  late TtsService service;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tts = _FakeFlutterTts();
    service = TtsService(ttsFactory: () => tts);
    await _waitForInitialization(service);
    expect(service.isInitialized, isTrue, reason: service.lastError);
  });

  tearDown(() async {
    await service.stop();
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    debugDefaultTargetPlatformOverride = null;
  });

  test('configures the iOS spoken-audio session before activating it', () {
    expect(service.supportsQueuedText, isTrue);

    final categoryIndex = tts.calls.indexOf('setIosAudioCategory');
    final autoStopIndex = tts.calls.indexOf('autoStopSharedSession:false');
    final sharedInstanceIndex = tts.calls.indexOf('setSharedInstance:true');

    expect(categoryIndex, greaterThanOrEqualTo(0), reason: '${tts.calls}');
    expect(autoStopIndex, greaterThan(categoryIndex));
    expect(sharedInstanceIndex, greaterThan(autoStopIndex));
    expect(tts.iosCategory, IosTextToSpeechAudioCategory.playback);
    expect(tts.iosOptions, isEmpty);
    expect(tts.iosMode, IosTextToSpeechAudioMode.spokenAudio);
    expect(tts.calls.where((call) => call.startsWith('setQueueMode')), isEmpty);
  });

  test(
    'submits iOS queued speech in FIFO order and restores await mode',
    () async {
      tts.calls.clear();
      final started = <int>[];

      final batch = service.speakQueued(const <String>[
        '第一句。',
        '第二句。',
      ], onTextStarted: started.add);
      await _waitFor(() => tts.spokenTexts.length == 2);

      expect(tts.spokenTexts, <String>['第一句。', '第二句。']);
      expect(
        tts.calls.where((call) => call.startsWith('setQueueMode')),
        isEmpty,
      );

      tts.emitStart();
      tts.emitComplete();
      tts.emitStart();
      tts.emitComplete();
      await batch;

      expect(started, <int>[0, 1]);
      expect(
        tts.calls.where((call) => call.startsWith('awaitSpeakCompletion')),
        <String>['awaitSpeakCompletion:false', 'awaitSpeakCompletion:true'],
      );
      expect(service.isPlaying, isFalse);
    },
  );

  test('stop cancels an iOS batch and restores await mode once', () async {
    tts.calls.clear();

    final batch = service.speakQueued(const <String>[
      '第一句。',
      '第二句。',
      '第三句。',
    ], onTextStarted: (_) {});
    await _waitFor(() => tts.spokenTexts.length == 3);
    tts.emitStart();

    await service.stop();
    await batch;

    expect(
      tts.calls.where((call) => call.startsWith('awaitSpeakCompletion')),
      <String>['awaitSpeakCompletion:false', 'awaitSpeakCompletion:true'],
    );
    expect(tts.calls.where((call) => call.startsWith('setQueueMode')), isEmpty);
    expect(service.isPlaying, isFalse);
    expect(service.isPaused, isFalse);
  });

  test('a replacement batch wins an in-flight queue-mode transition', () async {
    tts.calls.clear();
    final firstModeGate = Completer<void>();
    tts.awaitFalseGate = firstModeGate;

    final first = service.speakQueued(const <String>[
      '旧句。',
    ], onTextStarted: (_) {});
    await _waitFor(() => tts.calls.contains('awaitSpeakCompletion:false'));

    final second = service.speakQueued(const <String>[
      '新句一。',
      '新句二。',
    ], onTextStarted: (_) {});
    firstModeGate.complete();
    await first;
    await _waitFor(() => tts.spokenTexts.length == 2);

    expect(tts.spokenTexts, <String>['新句一。', '新句二。']);
    expect(
      tts.calls.where((call) => call.startsWith('awaitSpeakCompletion')),
      <String>[
        'awaitSpeakCompletion:false',
        'awaitSpeakCompletion:true',
        'awaitSpeakCompletion:false',
      ],
    );

    tts.emitStart();
    tts.emitComplete();
    tts.emitStart();
    tts.emitComplete();
    await second;

    expect(
      tts.calls.where((call) => call.startsWith('awaitSpeakCompletion')).last,
      'awaitSpeakCompletion:true',
    );
  });

  test('a failed iOS utterance still restores await mode', () async {
    tts.calls.clear();
    tts.nextSpeakResult = 0;

    await expectLater(
      service.speakQueued(const <String>['失败句。'], onTextStarted: (_) {}),
      throwsA(isA<StateError>()),
    );

    expect(
      tts.calls.where((call) => call.startsWith('awaitSpeakCompletion')),
      <String>['awaitSpeakCompletion:false', 'awaitSpeakCompletion:true'],
    );
    expect(service.isPlaying, isFalse);
    expect(service.lastError, 'tts_call_failed');
  });

  test('single speech replaces an in-flight queued-mode transition', () async {
    tts.calls.clear();
    final queueModeGate = Completer<void>();
    tts.awaitFalseGate = queueModeGate;

    final batch = service.speakQueued(const <String>[
      '不应播放。',
    ], onTextStarted: (_) {});
    await _waitFor(() => tts.calls.contains('awaitSpeakCompletion:false'));

    final replacement = service.speak('替换单句。');
    queueModeGate.complete();
    await batch;
    await replacement;

    expect(tts.spokenTexts, <String>['替换单句。']);
    final replacementIndex = tts.calls.indexOf('speak:替换单句。');
    final lastRestoreIndex = tts.calls.lastIndexOf('awaitSpeakCompletion:true');
    expect(lastRestoreIndex, lessThan(replacementIndex));
    expect(tts.calls.where((call) => call.startsWith('setQueueMode')), isEmpty);
  });
}

class _FakeFlutterTts extends FlutterTts {
  final List<String> calls = <String>[];
  final List<String> spokenTexts = <String>[];
  IosTextToSpeechAudioCategory? iosCategory;
  List<IosTextToSpeechAudioCategoryOptions>? iosOptions;
  IosTextToSpeechAudioMode? iosMode;
  Completer<void>? awaitFalseGate;
  dynamic nextSpeakResult = 1;

  VoidCallback? _start;
  VoidCallback? _complete;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async {
    calls.add('awaitSpeakCompletion:$awaitCompletion');
    if (!awaitCompletion) {
      final gate = awaitFalseGate;
      if (gate != null) {
        await gate.future;
        if (identical(awaitFalseGate, gate)) awaitFalseGate = null;
      }
    }
    return 1;
  }

  @override
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) async {
    calls.add('setIosAudioCategory');
    iosCategory = category;
    iosOptions = List<IosTextToSpeechAudioCategoryOptions>.of(options);
    iosMode = mode;
    return 1;
  }

  @override
  Future<dynamic> autoStopSharedSession(bool autoStop) async {
    calls.add('autoStopSharedSession:$autoStop');
    return 1;
  }

  @override
  Future<dynamic> setSharedInstance(bool sharedSession) async {
    calls.add('setSharedInstance:$sharedSession');
    return 1;
  }

  @override
  Future<dynamic> get getLanguages async => <String>['zh-CN', 'en-US'];

  @override
  Future<dynamic> isLanguageAvailable(String language) async => true;

  @override
  Future<dynamic> setLanguage(String language) async => 1;

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    calls.add('speak:$text');
    spokenTexts.add(text);
    final result = nextSpeakResult;
    nextSpeakResult = 1;
    return result;
  }

  @override
  Future<dynamic> stop() async {
    calls.add('stop');
    return 1;
  }

  @override
  Future<dynamic> setQueueMode(int queueMode) async {
    calls.add('setQueueMode:$queueMode');
    return 1;
  }

  @override
  void setStartHandler(VoidCallback callback) {
    _start = callback;
  }

  @override
  void setCompletionHandler(VoidCallback callback) {
    _complete = callback;
  }

  void emitStart() => _start?.call();

  void emitComplete() => _complete?.call();
}

Future<void> _waitForInitialization(TtsService service) async {
  if (service.isInitialized) return;
  final completer = Completer<void>();

  void listener() {
    if (service.isInitialized ||
        (!service.isInitializing && service.lastError != null)) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  service.addListener(listener);
  listener();
  await completer.future.timeout(const Duration(seconds: 3));
  service.removeListener(listener);
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
