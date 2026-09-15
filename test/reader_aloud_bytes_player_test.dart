import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/reader_aloud_service.dart';

void main() {
  test(
    'creating a cloud or preview player does not change the shared session',
    () {
      final native = _Player();
      final player = AudioplayersReaderAloudBytesPlayer(player: native);
      addTearDown(player.dispose);
      expect(native.contexts, isEmpty);
    },
  );

  test('cloud playback restores nonmixable playback after a preview', () async {
    final session = _Session();
    final native = _Player(session: session);
    final previewNative = _Player(session: session);
    final player = AudioplayersReaderAloudBytesPlayer(player: native);
    final preview = AudioplayersReaderAloudBytesPlayer(player: previewNative);
    addTearDown(player.dispose);
    addTearDown(preview.dispose);

    await _play(player);
    await _play(preview);
    // Another plugin changed the process-global policy while our player was idle.
    session.context = AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: {AVAudioSessionOptions.mixWithOthers},
    );
    await _play(player);

    expect(native.contexts, hasLength(2));
    expect(previewNative.contexts, hasLength(1));
    for (final context in [
      ...native.playedContexts,
      ...previewNative.playedContexts,
    ]) {
      expect(context.category, AVAudioSessionCategory.playback);
      expect(context.options, isEmpty);
    }
    expect(native.volumes, [0.6, 0.6]);
    expect(player.isPlaying, isFalse);
  });

  for (final action in ['stop', 'pause', 'dispose']) {
    test('$action during session setup cancels late playback', () async {
      final gate = Completer<void>();
      final native = _Player(contextGate: gate);
      final player = AudioplayersReaderAloudBytesPlayer(player: native);
      if (action != 'dispose') addTearDown(player.dispose);
      final playing = _play(player);
      await native.contextStarted.future;
      if (action == 'dispose') {
        player.dispose();
      } else if (action == 'pause') {
        await player.pause();
      } else {
        await player.stop();
      }
      gate.complete();
      await playing;
      expect(native.playedContexts, isEmpty);
      expect(player.isPlaying, isFalse);
    });
  }

  test('session setup failure is reported and can be retried', () async {
    final native = _Player()..failContext = true;
    final player = AudioplayersReaderAloudBytesPlayer(player: native);
    addTearDown(player.dispose);
    await expectLater(_play(player), throwsStateError);
    expect(native.playedContexts, isEmpty);
    expect(player.isPlaying, isFalse);
    native.failContext = false;
    await _play(player);
    expect(native.playedContexts, hasLength(1));
  });
}

Future<void> _play(AudioplayersReaderAloudBytesPlayer player) => player.play(
  Uint8List.fromList([1, 2, 3]),
  mimeType: 'audio/mpeg',
  volume: 0.6,
);

class _Session {
  AudioContextIOS? context;
}

class _Player implements AudioPlayer {
  _Player({_Session? session, this.contextGate})
    : session = session ?? _Session();

  final _Session session;
  final Completer<void>? contextGate;
  final contextStarted = Completer<void>();
  final contexts = <AudioContext>[];
  final playedContexts = <AudioContextIOS>[];
  final volumes = <double?>[];
  final _completed = StreamController<void>.broadcast();
  bool failContext = false;

  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => _completed.stream;

  @override
  Future<void> setAudioContext(AudioContext context) async {
    contexts.add(context);
    if (!contextStarted.isCompleted) contextStarted.complete();
    await contextGate?.future;
    if (failContext) throw StateError('Session unavailable');
    session.context = context.iOS;
  }

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    playedContexts.add(session.context!);
    volumes.add(volume);
    _completed.add(null);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() => _completed.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
