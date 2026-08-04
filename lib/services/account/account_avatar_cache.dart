import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

typedef AccountAvatarLoader = Future<Uint8List> Function(Uri uri);

class AccountAvatarCache {
  AccountAvatarCache({
    Dio? dio,
    AccountAvatarLoader? loader,
    this.cacheDirectory,
    this.maxDiskAge = const Duration(days: 14),
    this.maxImageBytes = 4 * 1024 * 1024,
    this.maxMemoryBytes = 8 * 1024 * 1024,
  }) : assert(maxImageBytes > 0),
       assert(maxMemoryBytes > 0) {
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 12),
            sendTimeout: const Duration(seconds: 8),
            responseType: ResponseType.bytes,
            headers: const {'Accept': 'image/*'},
          ),
        );
    _loader = loader ?? _download;
  }

  static final AccountAvatarCache instance = AccountAvatarCache();
  static const directoryName = 'account_avatars';

  final Duration maxDiskAge;
  final int maxImageBytes;
  final int maxMemoryBytes;
  final Directory? cacheDirectory;

  late final Dio _dio;
  late final AccountAvatarLoader _loader;
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  final Map<String, Future<Uint8List>> _inFlight = {};
  final Map<String, int> _keyEpochs = {};
  int _cacheEpoch = 0;
  int _memoryBytes = 0;

  int get memorySizeBytes => _memoryBytes;

  Future<Uint8List> load(Uri uri) {
    _validateUri(uri);
    final key = _key(uri);
    final memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      return Future.value(memory);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;

    late final Future<Uint8List> tracked;
    tracked = () async {
      try {
        return await _load(uri, key, (_cacheEpoch, _keyEpochs[key] ?? 0));
      } finally {
        if (identical(_inFlight[key], tracked)) _inFlight.remove(key);
      }
    }();
    _inFlight[key] = tracked;
    return tracked;
  }

  Future<Uint8List> _load(Uri uri, String key, (int, int) epoch) async {
    final disk = await _readDisk(key);
    if (disk != null) {
      if (_isCurrent(key, epoch)) _remember(key, disk);
      return disk;
    }
    final bytes = await _loader(uri);
    _validateBytes(bytes);
    if (_isCurrent(key, epoch)) {
      _remember(key, bytes);
      await _writeDisk(key, bytes);
    }
    return bytes;
  }

  Future<Uint8List> _download(Uri uri) async {
    final response = await _dio.get<List<int>>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (status) => status == HttpStatus.ok,
      ),
    );
    final contentType = response.headers.value(Headers.contentTypeHeader) ?? '';
    if (!contentType.toLowerCase().startsWith('image/')) {
      throw const FormatException('Avatar response is not an image.');
    }
    final bytes = Uint8List.fromList(response.data ?? const []);
    _validateBytes(bytes);
    return bytes;
  }

  void _validateUri(Uri uri) {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Invalid avatar URL.');
    }
  }

  void _validateBytes(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('Avatar is empty.');
    if (bytes.lengthInBytes > maxImageBytes) {
      throw FormatException('Avatar exceeds $maxImageBytes bytes.');
    }
  }

  void _remember(String key, Uint8List bytes) {
    final replaced = _memory.remove(key);
    if (replaced != null) _memoryBytes -= replaced.lengthInBytes;
    _memory[key] = bytes;
    _memoryBytes += bytes.lengthInBytes;
    while (_memoryBytes > maxMemoryBytes && _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      _memoryBytes -= _memory.remove(oldestKey)!.lengthInBytes;
    }
  }

  Future<Uint8List?> _readDisk(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      if (DateTime.now().difference(await file.lastModified()) > maxDiskAge) {
        await file.delete();
        return null;
      }
      final bytes = await file.readAsBytes();
      _validateBytes(bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    try {
      final file = await _fileFor(key);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.part');
      await temporary.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } catch (_) {
      // Avatar display must not fail because a cache write failed.
    }
  }

  Future<Directory> directory() async {
    if (cacheDirectory != null) return cacheDirectory!;
    final root = await getApplicationCacheDirectory();
    return Directory(path.join(root.path, directoryName));
  }

  Future<File> _fileFor(String key) async =>
      File(path.join((await directory()).path, '$key.img'));

  String _key(Uri uri) =>
      sha256.convert(utf8.encode(uri.toString())).toString();

  bool _isCurrent(String key, (int, int) epoch) =>
      epoch.$1 == _cacheEpoch && epoch.$2 == (_keyEpochs[key] ?? 0);

  Future<void> evict(Uri uri) async {
    _validateUri(uri);
    final key = _key(uri);
    _keyEpochs[key] = (_keyEpochs[key] ?? 0) + 1;
    _inFlight.remove(key);
    final memory = _memory.remove(key);
    if (memory != null) _memoryBytes -= memory.lengthInBytes;
    final file = await _fileFor(key);
    if (await file.exists()) await file.delete();
  }

  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  Future<void> clearDisk() async {
    _cacheEpoch++;
    _keyEpochs.clear();
    final cacheDirectory = await directory();
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  }

  Future<void> clear() async {
    clearMemory();
    await clearDisk();
  }

  Future<int> diskSizeBytes() async {
    final cacheDirectory = await directory();
    if (!await cacheDirectory.exists()) return 0;
    var total = 0;
    await for (final entity in cacheDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } catch (_) {
        // Ignore entries removed concurrently by cache cleanup.
      }
    }
    return total;
  }
}
