import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/services/account/account_avatar_cache.dart';

void main() {
  test(
    'reuses account avatar bytes from disk after memory is cleared',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'account-avatar-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final cache = AccountAvatarCache(
        cacheDirectory: directory,
        loader: (_) async {
          calls++;
          return Uint8List.fromList([1, 2, 3, 4]);
        },
      );
      final uri = Uri.parse('https://example.org/avatar.png?v=1');

      expect(await cache.load(uri), [1, 2, 3, 4]);
      cache.clearMemory();
      expect(await cache.load(uri), [1, 2, 3, 4]);
      expect(calls, 1);
      expect(await cache.diskSizeBytes(), 4);
    },
  );

  test('evict forces a same-url avatar to be downloaded again', () async {
    final directory = await Directory.systemTemp.createTemp('account-avatar-');
    addTearDown(() => directory.delete(recursive: true));
    var revision = 0;
    final cache = AccountAvatarCache(
      cacheDirectory: directory,
      loader: (_) async => Uint8List.fromList([++revision]),
    );
    final uri = Uri.parse('https://example.org/avatar.png');

    expect(await cache.load(uri), [1]);
    await cache.evict(uri);
    expect(await cache.load(uri), [2]);
    expect(revision, 2);
  });
}
