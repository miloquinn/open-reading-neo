import 'package:flutter/widgets.dart';

typedef ImageRetryErrorReporter =
    void Function(Object error, StackTrace stackTrace);
typedef ImageRetryScheduler = void Function(VoidCallback callback);

class ImageDecodeRetryController {
  ImageDecodeRetryController({ImageRetryScheduler? scheduler})
    : _scheduler = scheduler ?? _scheduleAfterFrame;

  final ImageRetryScheduler _scheduler;
  bool _attempted = false;
  bool _scheduled = false;
  int _generation = 0;

  void reset() {
    _generation++;
    _attempted = false;
    _scheduled = false;
  }

  void schedule({
    required bool Function() isMounted,
    required Future<void> Function() evict,
    required VoidCallback reload,
    ImageRetryErrorReporter? onError,
  }) {
    if (_attempted || _scheduled) return;
    _scheduled = true;
    final generation = _generation;
    _scheduler(() async {
      if (generation != _generation || !isMounted()) return;
      _scheduled = false;
      _attempted = true;
      try {
        await evict();
        if (generation != _generation || !isMounted()) return;
        reload();
      } catch (error, stackTrace) {
        final reporter = onError ?? _debugReportImageRetryError;
        reporter(error, stackTrace);
      }
    });
  }
}

void _scheduleAfterFrame(VoidCallback callback) {
  WidgetsBinding.instance.addPostFrameCallback((_) => callback());
}

void _debugReportImageRetryError(Object error, StackTrace stackTrace) {
  debugPrint('Image cache retry failed (${error.runtimeType}).');
  debugPrintStack(stackTrace: stackTrace);
}
