import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/export/reading_data_export_backend_io.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp(
      'reading-data-export-backend-',
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('desktop cancellation does not create a file', () async {
    final backend = IoReadingDataExportBackend(
      platform: TargetPlatform.macOS,
      saveFilePicker: (_) async => null,
    );

    final result = await backend.export(_request());

    expect(result.status, ReadingDataExportStatus.cancelled);
    expect(await sandbox.list().isEmpty, isTrue);
  });

  test('desktop existing destination requires explicit confirmation', () async {
    final destination = File('${sandbox.path}/notes.md');
    await destination.writeAsString('old');
    var confirmations = 0;
    final backend = IoReadingDataExportBackend(
      platform: TargetPlatform.linux,
      saveFilePicker: (_) async => destination.path,
      overwriteConfirmation: (_) async {
        confirmations++;
        return false;
      },
    );

    final result = await backend.export(_request());

    expect(result.status, ReadingDataExportStatus.cancelled);
    expect(confirmations, 1);
    expect(await destination.readAsString(), 'old');
  });

  test('desktop confirmed overwrite replaces file atomically', () async {
    final destination = File('${sandbox.path}/notes.md');
    await destination.writeAsString('old');
    final backend = IoReadingDataExportBackend(
      platform: TargetPlatform.windows,
      saveFilePicker: (_) async => destination.path,
      overwriteConfirmation: (_) async => true,
    );

    final result = await backend.export(_request());

    expect(result.status, ReadingDataExportStatus.success);
    expect(await destination.readAsString(), '# New\n');
    final leftovers = await sandbox
        .list()
        .where((entry) => entry.path.contains('.partial'))
        .toList();
    expect(leftovers, isEmpty);
  });
}

ReadingDataExportRequest _request() => ReadingDataExportRequest(
  bytes: Uint8List.fromList('# New\n'.codeUnits),
  suggestedName: 'notes.md',
);
