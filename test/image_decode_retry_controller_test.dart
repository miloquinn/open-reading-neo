import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/image_decode_retry_controller.dart';

void main() {
  test('decode retry evicts and reloads at most once', () async {
    final callbacks = <void Function()>[];
    final controller = ImageDecodeRetryController(scheduler: callbacks.add);
    var evictions = 0;
    var reloads = 0;

    void schedule() => controller.schedule(
      isMounted: () => true,
      evict: () async => evictions++,
      reload: () => reloads++,
    );

    schedule();
    schedule();
    callbacks.removeAt(0)();
    await Future<void>.delayed(Duration.zero);
    schedule();

    expect(evictions, 1);
    expect(reloads, 1);
  });

  test('reset cancels stale callbacks and permits the new image', () async {
    final callbacks = <void Function()>[];
    final controller = ImageDecodeRetryController(scheduler: callbacks.add);
    var staleEvictions = 0;
    var currentEvictions = 0;

    controller.schedule(
      isMounted: () => true,
      evict: () async => staleEvictions++,
      reload: () {},
    );
    controller.reset();
    controller.schedule(
      isMounted: () => true,
      evict: () async => currentEvictions++,
      reload: () {},
    );
    for (final callback in callbacks) {
      callback();
    }
    await Future<void>.delayed(Duration.zero);

    expect(staleEvictions, 0);
    expect(currentEvictions, 1);
  });

  test('retry failures are reported while fallback remains active', () async {
    final callbacks = <void Function()>[];
    final controller = ImageDecodeRetryController(scheduler: callbacks.add);
    final errors = <Object>[];

    controller.schedule(
      isMounted: () => true,
      evict: () async => throw StateError('cache eviction failed'),
      reload: () => fail('failed eviction must not reload'),
      onError: (error, _) => errors.add(error),
    );
    callbacks.single();
    await Future<void>.delayed(Duration.zero);

    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
  });
}
