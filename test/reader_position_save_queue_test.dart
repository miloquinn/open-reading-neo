import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_position_save_queue.dart';

void main() {
  test(
    'serializes progress writes and flush waits for the latest position',
    () async {
      final queue = ReaderPositionSaveQueue();
      final firstWrite = Completer<void>();
      final secondWrite = Completer<void>();
      final events = <String>[];

      queue.enqueue(() async {
        events.add('first-start');
        await firstWrite.future;
        events.add('first-finish');
      });
      queue.enqueue(() async {
        events.add('second-start');
        await secondWrite.future;
        events.add('second-finish');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);

      var flushed = false;
      final flush = queue.flush().then((_) => flushed = true);
      firstWrite.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start', 'first-finish', 'second-start']);
      expect(flushed, isFalse);

      secondWrite.complete();
      await flush;
      expect(events, [
        'first-start',
        'first-finish',
        'second-start',
        'second-finish',
      ]);
      expect(flushed, isTrue);
    },
  );

  test(
    'a failed write does not prevent the latest position from saving',
    () async {
      final errors = <Object>[];
      final queue = ReaderPositionSaveQueue(
        onError: (error, _) => errors.add(error),
      );
      var savedPosition = 0;

      queue.enqueue(() => Future<void>.error(StateError('write failed')));
      queue.enqueue(() async => savedPosition = 20);

      await queue.flush();

      expect(errors, hasLength(1));
      expect(savedPosition, 20);
    },
  );
}
