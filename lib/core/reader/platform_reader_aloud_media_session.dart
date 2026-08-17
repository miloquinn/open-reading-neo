import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reader_aloud_controller.dart';

/// Connects the reader-aloud session to the platform media controls.
///
/// Android renders a media-style foreground notification while iOS publishes
/// Now Playing metadata and remote commands. Both platforms intentionally use
/// the same channel protocol so the playback controller remains platform
/// independent.
class PlatformReaderAloudMediaSession implements ReaderAloudNotificationSink {
  PlatformReaderAloudMediaSession({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.niki.xxread/reader_aloud');

  static final PlatformReaderAloudMediaSession instance =
      PlatformReaderAloudMediaSession();

  final MethodChannel _channel;
  final StreamController<ReaderAloudControl> _controls =
      StreamController<ReaderAloudControl>.broadcast();
  bool _initialized = false;
  bool _permissionRequested = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Stream<ReaderAloudControl> get controls => _controls.stream;

  Future<void> initialize() async {
    if (_initialized || !_isSupported) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'control') return;
      final control = switch (call.arguments?.toString()) {
        'previous' => ReaderAloudControl.previous,
        'play' => ReaderAloudControl.play,
        'pause' => ReaderAloudControl.pause,
        'playPause' => ReaderAloudControl.playPause,
        'next' => ReaderAloudControl.next,
        'refresh' => ReaderAloudControl.refresh,
        'stop' => ReaderAloudControl.stop,
        _ => null,
      };
      if (control != null && !_controls.isClosed) {
        _controls.add(control);
      }
    });
  }

  @override
  Future<void> show(ReaderAloudNotificationData data) async {
    if (!_isSupported) return;
    await initialize();
    if (_isAndroid && !_permissionRequested) {
      _permissionRequested = true;
      await _channel.invokeMethod<void>('requestNotificationPermission');
    }
    await _channel.invokeMethod<void>('show', <String, Object?>{
      'bookTitle': data.bookTitle,
      'chapterTitle': data.chapterTitle,
      'state': data.state.name,
      'chapterIndex': data.chapterIndex,
      'chapterCount': data.chapterCount,
      'progress': data.progress,
    });
  }

  @override
  Future<void> stop() async {
    if (!_isSupported || !_initialized) return;
    await _channel.invokeMethod<void>('stop');
  }

  @visibleForTesting
  Future<void> dispose() async {
    if (_initialized) {
      _channel.setMethodCallHandler(null);
    }
    await _controls.close();
  }
}
