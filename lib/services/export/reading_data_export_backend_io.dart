import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';
import 'package:xxread/services/storage/platform_storage_bridge.dart';

typedef ReadingDataSaveFilePicker = Future<String?> Function(String name);
ReadingDataExportBackend createDefaultReadingDataExportBackend({
  ReadingDataOverwriteConfirmation? overwriteConfirmation,
}) => IoReadingDataExportBackend(overwriteConfirmation: overwriteConfirmation);

class IoReadingDataExportBackend implements ReadingDataExportBackend {
  IoReadingDataExportBackend({
    PlatformStorageBridge? platformBridge,
    ReadingDataSaveFilePicker? saveFilePicker,
    ReadingDataOverwriteConfirmation? overwriteConfirmation,
    TargetPlatform? platform,
  }) : _bridge = platformBridge ?? PlatformStorageBridge(),
       _saveFilePicker = saveFilePicker ?? _pickSavePath,
       _overwriteConfirmation = overwriteConfirmation ?? ((_) async => false),
       _platform = platform ?? defaultTargetPlatform;

  final PlatformStorageBridge _bridge;
  final ReadingDataSaveFilePicker _saveFilePicker;
  final ReadingDataOverwriteConfirmation _overwriteConfirmation;
  final TargetPlatform _platform;

  static Future<String?> _pickSavePath(String name) => FilePicker.saveFile(
    fileName: name,
    type: FileType.custom,
    allowedExtensions: const ['md'],
    lockParentWindow: true,
  );

  @override
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  ) async {
    if (_platform == TargetPlatform.android ||
        _platform == TargetPlatform.iOS) {
      final temporaryRoot = await getTemporaryDirectory();
      final exportDirectory = await Directory(
        path.join(temporaryRoot.path, 'reading-data-export'),
      ).create(recursive: true);
      final temporary = File(
        path.join(
          exportDirectory.path,
          'open-reading-${DateTime.now().microsecondsSinceEpoch}-${request.suggestedName}',
        ),
      );
      try {
        await temporary.writeAsBytes(request.bytes, flush: true);
        final row = _platform == TargetPlatform.android
            ? await _bridge.exportBookToDownloads(
                sourcePath: temporary.path,
                displayName: request.suggestedName,
                mimeType: 'text/plain',
              )
            : await _bridge.exportDocument(
                sourcePath: temporary.path,
                displayName: request.suggestedName,
                mimeType: 'text/plain',
              );
        return _fromNative(row);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    if (_platform != TargetPlatform.windows &&
        _platform != TargetPlatform.macOS &&
        _platform != TargetPlatform.linux) {
      return const ReadingDataExportBackendResult.unsupported();
    }
    final selected = await _saveFilePicker(request.suggestedName);
    if (selected == null || selected.isEmpty) {
      return const ReadingDataExportBackendResult.cancelled();
    }
    final destination = File(selected);
    if (await destination.exists() &&
        !await _overwriteConfirmation(destination.path)) {
      return const ReadingDataExportBackendResult.cancelled();
    }
    await _writeAtomically(destination, request.bytes);
    return ReadingDataExportBackendResult.success(
      displayName: path.basename(destination.path),
      location: destination.path,
    );
  }

  ReadingDataExportBackendResult _fromNative(Map<String, Object?> row) =>
      switch (row['status']?.toString()) {
        'success' => ReadingDataExportBackendResult.success(
          displayName: row['displayName']?.toString() ?? '',
          location:
              row['displayLocation']?.toString() ??
              row['destinationPath']?.toString() ??
              row['location']?.toString(),
          uri: row['uri']?.toString(),
        ),
        'cancelled' => const ReadingDataExportBackendResult.cancelled(),
        'unsupported' => const ReadingDataExportBackendResult.unsupported(),
        _ => ReadingDataExportBackendResult.failure(row['errorCode']),
      };

  Future<void> _writeAtomically(File destination, List<int> bytes) async {
    await destination.parent.create(recursive: true);
    final partial = File(
      '${destination.path}.open-reading-${DateTime.now().microsecondsSinceEpoch}.partial',
    );
    File? backup;
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await destination.exists()) {
        backup = File('${partial.path}.backup');
        await destination.rename(backup.path);
      }
      await partial.rename(destination.path);
      if (backup != null && await backup.exists()) await backup.delete();
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      if (backup != null && await backup.exists()) {
        if (await destination.exists()) await destination.delete();
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }
}
