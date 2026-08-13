import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/platform_reader_aloud_media_session.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.reader_aloud/media_session');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'requestNotificationPermission' ? true : null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'publishes iOS Now Playing data without notification permission',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final mediaSession = PlatformReaderAloudMediaSession(channel: channel);
      addTearDown(mediaSession.dispose);

      await mediaSession.show(_data);
      await mediaSession.stop();

      expect(calls.map((call) => call.method), ['show', 'stop']);
      expect(calls.first.arguments, {
        'bookTitle': 'Test Book',
        'chapterTitle': 'Chapter 2',
        'state': 'playing',
        'chapterIndex': 1,
        'chapterCount': 8,
        'progress': 0.25,
      });
    },
  );

  test('requests Android notification permission only once', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final mediaSession = PlatformReaderAloudMediaSession(channel: channel);
    addTearDown(mediaSession.dispose);

    await mediaSession.show(_data);
    await mediaSession.show(_data);

    expect(calls.map((call) => call.method), [
      'requestNotificationPermission',
      'show',
      'show',
    ]);
  });

  test('maps explicit iOS play and pause commands without toggling', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final mediaSession = PlatformReaderAloudMediaSession(channel: channel);
    addTearDown(mediaSession.dispose);
    await mediaSession.initialize();
    final received = <ReaderAloudControl>[];
    final subscription = mediaSession.controls.listen(received.add);
    addTearDown(subscription.cancel);

    await _sendPlatformCall(channel, const MethodCall('control', 'play'));
    await _sendPlatformCall(channel, const MethodCall('control', 'pause'));
    await _sendPlatformCall(channel, const MethodCall('control', 'playPause'));
    await _sendPlatformCall(channel, const MethodCall('control', 'refresh'));
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      ReaderAloudControl.play,
      ReaderAloudControl.pause,
      ReaderAloudControl.playPause,
      ReaderAloudControl.refresh,
    ]);
  });
}

const _data = ReaderAloudNotificationData(
  bookTitle: 'Test Book',
  chapterTitle: 'Chapter 2',
  state: ReaderAloudPlaybackState.playing,
  chapterIndex: 1,
  chapterCount: 8,
  progress: 0.25,
);

Future<void> _sendPlatformCall(MethodChannel channel, MethodCall call) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(call),
        (_) {},
      );
}
