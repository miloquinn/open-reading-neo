import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../book_sources/services/book_source_registry_storage.dart';
import '../core/database_service.dart';
import '../sync/secure_sync_config.dart';
import '../sync/sync_models.dart';
import '../sync/webdav_client.dart';
import 'backup_archive.dart';
import 'backup_selection.dart';

class CloudBackup {
  const CloudBackup(this.name, this.createdAt, this.bytes);
  final String name;
  final DateTime createdAt;
  final int? bytes;
}

class WebDavBackupController extends ChangeNotifier {
  WebDavBackupController({
    SecureSyncConfigStore? configStore,
    WebDavClientFactory? clientFactory,
    Future<BackupArchive> Function()? archiveFactory,
  }) : _configStore = configStore ?? SecureSyncConfigStore(),
       _clientFactory = clientFactory ?? WebDavClient.standard,
       _archiveFactory = archiveFactory ?? _defaultArchive;
  final SecureSyncConfigStore _configStore;
  final WebDavClientFactory _clientFactory;
  final Future<BackupArchive> Function() _archiveFactory;
  WebDavSyncConfiguration? _configuration;
  bool busy = false;
  bool _disposed = false;
  double? progress;
  RestoreSelection restoreSelection = const RestoreSelection();
  BackupSelection selection = const BackupSelection();
  List<BackupBook> books = const [];
  String stage = '';
  int completedBytes = 0, totalBytes = 0;
  double bytesPerSecond = 0;
  final Stopwatch _clock = Stopwatch();
  int _sampleBytes = 0, _sampleMilliseconds = 0, _lastNotify = -100;
  Timer? _speedTimer;

  Future<void> loadBooks() async {
    books = await (await _archiveFactory()).inventory();
    _changed();
  }

  void setSelection(BackupSelection value) {
    if (busy) return;
    selection = value;
    _changed();
  }

  void _stage(String value) {
    stage = value;
    progress = null;
    completedBytes = totalBytes = _sampleBytes = _sampleMilliseconds = 0;
    bytesPerSecond = 0;
    _lastNotify = -100;
    _clock.reset();
    _clock.start();
    _changed();
  }

  void _sampleSpeed() {
    if (stage != 'uploading' && stage != 'downloading') return;
    final now = _clock.elapsedMilliseconds;
    final elapsed = now - _sampleMilliseconds;
    if (elapsed <= 0) return;
    bytesPerSecond = (completedBytes - _sampleBytes) * 1000 / elapsed;
    _sampleBytes = completedBytes;
    _sampleMilliseconds = now;
    _changed();
  }

  List<CloudBackup> backups = const [];
  String? recoveryPath;
  bool get isConfigured => _configuration != null;
  String? get serverUrl => _configuration?.serverUrl;
  String? get username => _configuration?.username;
  String? get rootPath => _configuration?.rootPath;

  static Future<BackupArchive> _defaultArchive() async => BackupArchive(
    database: await DatabaseService().database,
    documents: await getApplicationDocumentsDirectory(),
    preferences: await SharedPreferences.getInstance(),
    sources: const DefaultBookSourceRegistryStorage(),
  );

  static Future<void> recoverPendingRestore() async {
    final documents = await getApplicationDocumentsDirectory();
    if (await File(
      p.join(documents.path, 'backups', 'restore-pending.json'),
    ).exists()) {
      await (await _defaultArchive()).recoverInterruptedRestore();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _disposed = true;
    super.dispose();
  }

  Future<void> initialize() async {
    _configuration = await _configStore.readConfiguration();
    _changed();
  }

  Future<StoredSyncCredentials> _credentials([
    WebDavSyncConfigDraft? draft,
  ]) async {
    final saved = await _configStore.readCredentials();
    if (draft == null) {
      if (saved == null) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.invalidConfiguration,
          'Configure WebDAV first.',
        );
      }
      return saved;
    }
    final password = draft.password.isEmpty
        ? saved?.password ?? ''
        : draft.password;
    final config = draft.withoutPassword();
    validateWebDavConfiguration(config, password: password);
    return StoredSyncCredentials(config, password);
  }

  Future<ConnectionTestResult> testConnection(WebDavSyncConfigDraft draft) =>
      _run(() async {
        try {
          return await _clientFactory(
            await _credentials(draft),
          ).testConnection();
        } on WebDavSyncFailure catch (e) {
          return ConnectionTestResult(
            success: false,
            errorCode: e.code,
            failure: e,
          );
        }
      });
  Future<void> configure(WebDavSyncConfigDraft draft) => _run(() async {
    final credentials = await _credentials(draft);
    await _configStore.save(credentials.configuration, credentials.password);
    _configuration = credentials.configuration;
    backups = const [];
  });
  Future<void> disconnect() => _run(() async {
    await _configStore.clear();
    _configuration = null;
    backups = const [];
  });
  Future<T> _run<T>(Future<T> Function() action) async {
    if (busy) throw StateError('A backup operation is already running');
    busy = true;
    _stage('preparing');
    _speedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sampleSpeed(),
    );
    _changed();
    try {
      return await action();
    } finally {
      _speedTimer?.cancel();
      _clock.stop();
      busy = false;
      stage = '';
      bytesPerSecond = 0;
      progress = null;
      _changed();
    }
  }

  void _transfer(int count, int total) {
    completedBytes = count;
    totalBytes = total;
    progress = total > 0 ? (count / total).clamp(0, 1) : null;
    if (_clock.elapsedMilliseconds - _sampleMilliseconds >= 500 ||
        count == total) {
      _sampleSpeed();
    }
    if (_clock.elapsedMilliseconds - _lastNotify >= 100 || count == total) {
      _lastNotify = _clock.elapsedMilliseconds;
      _changed();
    }
  }

  static final _name = RegExp(r'^open-reading-(\d+)-[a-f0-9-]+\.zip$');
  static const _folder = ['backups'];
  Future<List<CloudBackup>> _list(WebDavClient client) async {
    final root = client.rootPath(_folder);
    List<WebDavListEntry> entries;
    try {
      entries = await client.listEntries(root);
    } on WebDavSyncFailure catch (e) {
      if (e.statusCode == 404) return [];
      rethrow;
    }
    final byName = <String, WebDavListEntry>{};
    for (final entry in entries) {
      final parts = entry.uri.pathSegments;
      if (entry.isCollection ||
          parts.length != root.pathSegments.length + 1 ||
          !listEquals(
            parts.take(parts.length - 1).toList(),
            root.pathSegments,
          )) {
        continue;
      }
      byName[parts.last] = entry;
    }
    final result = <CloudBackup>[];
    for (final entry in byName.entries) {
      final match = _name.firstMatch(entry.key);
      if (match == null || !byName.containsKey('${entry.key}.complete')) {
        continue;
      }
      final timestamp = int.tryParse(match.group(1)!);
      if (timestamp == null || timestamp > 8640000000000000) continue;
      result.add(
        CloudBackup(
          entry.key,
          DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
          entry.value.contentLength,
        ),
      );
    }
    return result..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> refresh() => _run(() async {
    backups = await _list(_clientFactory(await _credentials()));
  });
  Future<void> backup() => _run(() async {
    final client = _clientFactory(await _credentials());
    final archive = await _archiveFactory();
    await archive.recoverInterruptedRestore();
    final temporary = await Directory.systemTemp.createTemp(
      'open-reading-backup-',
    );
    final name =
        'open-reading-${DateTime.now().toUtc().millisecondsSinceEpoch}-${const Uuid().v4()}.zip';
    final remote = client.rootPath([..._folder, name]);
    var uploaded = false;
    try {
      final zip = File(p.join(temporary.path, name));
      _stage('packing');
      await archive.create(
        zip,
        selection: selection,
        onProgress: _transfer,
        onVerifying: () => _stage('verifying'),
      );
      _stage('verifying');
      final hash = (await sha256.bind(zip.openRead()).first).toString();
      await client.ensureRootPath(_folder);
      _stage('uploading');
      await client.putFile(remote, zip, onProgress: _transfer);
      _stage('finishing');
      // Only snapshots with a completion marker appear in the restore list.
      // No MOVE, ETag, locking, or conditional writes are required.
      final marker = File(p.join(temporary.path, 'complete'));
      await marker.writeAsString(hash, flush: true);
      await client.putFile(
        client.rootPath([..._folder, '$name.complete']),
        marker,
      );
      uploaded = true;
      backups = [
        CloudBackup(name, DateTime.now().toUtc(), await zip.length()),
        ...backups,
      ];
    } finally {
      if (!uploaded) {
        try {
          await client.delete(remote);
        } catch (_) {}
      }
      await temporary.delete(recursive: true);
    }
  });
  Future<void> restore(CloudBackup backup) => _run(() async {
    if (!_name.hasMatch(backup.name)) {
      throw const FormatException('Invalid backup name');
    }
    final client = _clientFactory(await _credentials());
    final archive = await _archiveFactory();
    await archive.recoverInterruptedRestore();
    final temporary = await Directory.systemTemp.createTemp(
      'open-reading-restore-',
    );
    ValidatedBackup? validated;
    try {
      final hash = await client.getText(
        client.rootPath([..._folder, '${backup.name}.complete']),
      );
      if (hash == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('Incomplete backup');
      }
      final zip = File(p.join(temporary.path, 'restore.zip'));
      _stage('downloading');
      await client.downloadFile(
        client.rootPath([..._folder, backup.name]),
        zip,
        onProgress: _transfer,
      );
      _stage('verifying');
      if ((await sha256.bind(zip.openRead()).first).toString() != hash) {
        throw const FormatException('Backup checksum mismatch');
      }
      validated = await archive.validate(zip);
      final recovery = File(
        p.join(
          archive.documents.path,
          'backups',
          'before-restore-${const Uuid().v4()}.zip',
        ),
      );
      await recovery.parent.create(recursive: true);
      _stage('safety');
      await archive.create(
        recovery,
        selection: const BackupSelection(),
        onProgress: _transfer,
      );
      recoveryPath = recovery.path;
      _stage('restoring');
      await archive.restore(validated, selection: restoreSelection);
    } finally {
      if (validated != null) await validated.directory.delete(recursive: true);
      await temporary.delete(recursive: true);
    }
  });
}
