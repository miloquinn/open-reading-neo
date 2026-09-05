import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/services/core/cache_disk_budget.dart';

void main() {
  test('evicts the oldest whole group until the byte budget is met', () async {
    final directory = await Directory.systemTemp.createTemp('disk-budget-');
    addTearDown(() => directory.delete(recursive: true));
    final oldGroup = Directory('${directory.path}/old')..createSync();
    final newGroup = Directory('${directory.path}/new')..createSync();
    final oldIndex = File('${oldGroup.path}/index')..writeAsBytesSync([1, 2]);
    final oldData = File('${oldGroup.path}/data')..writeAsBytesSync([3, 4]);
    final newData = File('${newGroup.path}/data')..writeAsBytesSync([5, 6, 7]);
    final oldTime = DateTime.utc(2026, 1, 1);
    final newTime = DateTime.utc(2026, 1, 2);
    await oldIndex.setLastModified(oldTime);
    await oldIndex.setLastAccessed(oldTime);
    await oldData.setLastModified(oldTime);
    await oldData.setLastAccessed(oldTime);
    await newData.setLastModified(newTime);
    await newData.setLastAccessed(newTime);

    final budget = CacheDiskBudget(
      directory: directory,
      maxBytes: 3,
      maintenanceInterval: Duration.zero,
      groupKey: (file) => file.parent.path,
    );
    await budget.maintain(force: true);

    expect(await oldGroup.exists(), isFalse);
    expect(await newData.exists(), isTrue);
    expect(await budget.sizeBytes(), 3);
  });

  test('does not evict a protected group', () async {
    final directory = await Directory.systemTemp.createTemp(
      'disk-budget-protected-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final protected = Directory('${directory.path}/protected')..createSync();
    final other = Directory('${directory.path}/other')..createSync();
    final protectedFile = File('${protected.path}/data')
      ..writeAsBytesSync([1, 2, 3]);
    final otherFile = File('${other.path}/data')..writeAsBytesSync([4, 5, 6]);
    await protectedFile.setLastModified(DateTime.utc(2026, 1, 1));
    await protectedFile.setLastAccessed(DateTime.utc(2026, 1, 1));
    await otherFile.setLastModified(DateTime.utc(2026, 1, 2));
    await otherFile.setLastAccessed(DateTime.utc(2026, 1, 2));

    await CacheDiskBudget(
      directory: directory,
      maxBytes: 3,
      maintenanceInterval: Duration.zero,
      groupKey: (file) => file.parent.path,
    ).maintain(protectedPaths: {protected.path}, force: true);

    expect(await protectedFile.exists(), isTrue);
    expect(await other.exists(), isFalse);
  });

  test('removes expired groups even when they fit the byte budget', () async {
    final directory = await Directory.systemTemp.createTemp(
      'disk-budget-expiry-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final expired = File('${directory.path}/expired')..writeAsBytesSync([1]);
    final old = DateTime.now().subtract(const Duration(days: 2));
    await expired.setLastModified(old);
    await expired.setLastAccessed(old);

    await CacheDiskBudget(
      directory: directory,
      maxBytes: 100,
      maxAge: const Duration(days: 1),
    ).maintain(force: true);

    expect(await expired.exists(), isFalse);
  });

  test('throttles repeated maintenance scans', () async {
    final directory = await Directory.systemTemp.createTemp(
      'disk-budget-throttle-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var scans = 0;
    final budget = CacheDiskBudget(
      directory: directory,
      maxBytes: 10,
      maintenanceInterval: const Duration(hours: 1),
      onScan: () => scans++,
    );

    await budget.maintain();
    await budget.maintain();

    expect(scans, 1);
  });

  test(
    'rapid recorded growth forces maintenance when it crosses quota',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'disk-budget-growth-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var scans = 0;
      final budget = CacheDiskBudget(
        directory: directory,
        maxBytes: 10,
        maintenanceInterval: const Duration(hours: 1),
        onScan: () => scans++,
      );
      await budget.maintain(force: true);
      await File('${directory.path}/first').writeAsBytes(List.filled(6, 1));
      await budget.recordWrite(6);
      expect(scans, 1);
      await File('${directory.path}/second').writeAsBytes(List.filled(5, 2));

      await budget.recordWrite(5);

      expect(scans, 2);
      expect(await budget.sizeBytes(), lessThanOrEqualTo(10));
    },
  );
}
