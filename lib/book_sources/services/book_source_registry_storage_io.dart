import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const _registryDirectoryName = 'book_sources';
const _registryFileName = 'registry-v1.json';

bool get _usesTestPreferenceStore =>
    Platform.environment['FLUTTER_TEST'] == 'true';

Future<File> _registryFile() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return File(
    path.join(supportDirectory.path, _registryDirectoryName, _registryFileName),
  );
}

Future<String?> readBookSourceRegistry() async {
  if (_usesTestPreferenceStore) return null;
  try {
    final file = await _registryFile();
    await _restoreInterruptedCommit(file);
    if (!await file.exists()) return null;
    return file.readAsString();
  } on MissingPluginException {
    return null;
  }
}

Future<bool> writeBookSourceRegistry(String value) async {
  if (_usesTestPreferenceStore) return false;
  File? temporary;
  try {
    final file = await _registryFile();
    await file.parent.create(recursive: true);
    temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    await _restoreInterruptedCommit(file);
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsString(value, flush: true);
    if (await backup.exists()) await backup.delete();
    final hadExisting = await file.exists();
    if (hadExisting) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
      return true;
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  } on FileSystemException {
    try {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    } catch (_) {
      // Preserve the storage failure; cleanup is best effort.
    }
    return false;
  }
}

Future<void> _restoreInterruptedCommit(File file) async {
  final backup = File('${file.path}.backup');
  if (!await backup.exists()) return;
  if (await file.exists()) {
    await backup.delete();
    return;
  }
  await backup.rename(file.path);
}
