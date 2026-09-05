import 'dart:async';

import 'package:xxread/models/book.dart';

enum TxtContentChangeOrigin { localEdit, restore, remoteApply }

class TxtContentChanged {
  const TxtContentChanged({
    required this.book,
    required this.contentHash,
    required this.modifiedAt,
    required this.origin,
  });

  final Book book;
  final String contentHash;
  final DateTime modifiedAt;
  final TxtContentChangeOrigin origin;
}

/// Broadcast after a TXT file and its library metadata have both committed.
/// Sync listeners must ignore [TxtContentChangeOrigin.remoteApply] to avoid a
/// download-upload loop.
class TxtContentChangeBus {
  TxtContentChangeBus._();

  static final TxtContentChangeBus instance = TxtContentChangeBus._();

  final StreamController<TxtContentChanged> _controller =
      StreamController<TxtContentChanged>.broadcast();

  Stream<TxtContentChanged> get stream => _controller.stream;

  void notify(TxtContentChanged event) {
    if (!_controller.isClosed) _controller.add(event);
  }
}
