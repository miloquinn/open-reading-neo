import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/reader/reader_aloud_controller.dart';

/// App-scoped ownership for the active read-aloud controller.
///
/// A reader page may subscribe to this controller for highlighting, but it
/// must not own its lifetime: routes are routinely disposed while a user is
/// still listening from the notification, lock screen, or another app.
class ReaderAloudSession extends ChangeNotifier {
  ReaderAloudController? _controller;
  String? _sourceId;

  ReaderAloudController? get controller => _controller;
  String? get sourceId => _sourceId;
  bool get isActive => _controller?.isActive ?? false;

  ReaderAloudController acquire({
    required String sourceId,
    required ReaderAloudController Function() create,
  }) {
    final existing = _controller;
    if (existing != null && _sourceId == sourceId) return existing;

    if (existing != null) {
      existing.removeListener(_relayChange);
      // Switching books is an explicit replacement of the listening session.
      // Stopping first also clears the native media notification.
      unawaited(existing.stop());
      existing.dispose();
    }

    final controller = create();
    _controller = controller;
    _sourceId = sourceId;
    controller.addListener(_relayChange);
    notifyListeners();
    return controller;
  }

  Future<void> stop() async {
    await _controller?.stop();
  }

  void _relayChange() => notifyListeners();

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    _sourceId = null;
    if (controller != null) {
      controller.removeListener(_relayChange);
      controller.dispose();
    }
    super.dispose();
  }
}
