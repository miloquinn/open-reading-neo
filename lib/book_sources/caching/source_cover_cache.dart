import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../networking/book_source_network_policy.dart';
import '../source_engine/source_webview_loader.dart';

typedef SourceCoverLoader = Future<Uint8List> Function(Uri uri);

enum SourceImageLoadPriority { preload, visible }

const String _sourceCoverUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/124.0.0.0 Safari/537.36';

class SourceCoverLoadException implements Exception {
  const SourceCoverLoadException(this.message, {this.transient = false});

  final String message;
  final bool transient;

  @override
  String toString() => message;
}

/// Shared remote-cover loader for ORSP books.
///
/// Requests are deduplicated by URL, bounded per process, retried once for
/// transient failures, and cached in the platform cache directory. The cache is
/// deliberately separate from saved shelf covers, so clearing it never removes
/// a user's library artwork.
class SourceCoverCache {
  SourceCoverCache({
    Dio? dio,
    SourceCoverLoader? loader,
    this._cacheDirectory,
    this.cacheDirectoryName = directoryName,
    this.maxConcurrent = 4,
    this.retryDelay = const Duration(milliseconds: 350),
    this.maxDiskAge = const Duration(days: 7),
    this.maxImageBytes = 8 * 1024 * 1024,
    this.maxMemoryBytes = 24 * 1024 * 1024,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(),
    this._platformLoader = const SourceWebViewLoader(),
  }) : assert(maxConcurrent > 0),
       assert(maxImageBytes > 0),
       assert(maxMemoryBytes > 0),
       _networkPolicy = networkPolicy {
    _dio =
        dio ??
        (Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 8),
              responseType: ResponseType.bytes,
              headers: const {
                'Accept':
                    'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
                'User-Agent': _sourceCoverUserAgent,
              },
            ),
          )
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: networkPolicy.createPinnedHttpClient,
          ));
    _loader = loader ?? _download;
  }

  static final SourceCoverCache instance = SourceCoverCache();
  static final SourceCoverCache imagePageInstance = SourceCoverCache(
    cacheDirectoryName: imagePageDirectoryName,
    maxDiskAge: const Duration(days: 30),
    maxImageBytes: 24 * 1024 * 1024,
    maxMemoryBytes: 64 * 1024 * 1024,
  );
  static const String directoryName = 'source_covers';
  static const String imagePageDirectoryName = 'source_image_pages';

  final String cacheDirectoryName;
  final int maxConcurrent;
  final Duration retryDelay;
  final Duration maxDiskAge;
  final int maxImageBytes;
  final int maxMemoryBytes;
  final Directory? _cacheDirectory;
  final BookSourceNetworkPolicy _networkPolicy;
  final SourceWebViewLoaderPort _platformLoader;

  late final Dio _dio;
  late final SourceCoverLoader _loader;
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  final Map<String, Future<Uint8List>> _inFlight = {};
  final Queue<_SourceImageWaiter> _visibleWaiters = Queue();
  final Queue<_SourceImageWaiter> _preloadWaiters = Queue();
  final Map<String, int> _keyEpochs = {};
  int _active = 0;
  int _memoryBytes = 0;
  int _cacheEpoch = 0;

  int get activeRequests => _active;
  int get queuedVisibleRequests => _visibleWaiters.length;
  int get queuedPreloadRequests => _preloadWaiters.length;
  int get memorySizeBytes => _memoryBytes;

  Future<Uint8List> load(
    Uri uri, {
    Map<String, String> headers = const {},
    bool preferPlatform = false,
    SourceImageLoadPriority priority = SourceImageLoadPriority.visible,
  }) {
    _validateUri(uri);
    final normalizedHeaders = Map<String, String>.unmodifiable(headers);
    final key =
        '${preferPlatform ? 'platform' : 'default'}:${_key(uri, normalizedHeaders)}';
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
        return await _load(
          uri,
          key,
          normalizedHeaders,
          preferPlatform,
          priority,
          (_cacheEpoch, _keyEpochs[key] ?? 0),
        );
      } finally {
        if (identical(_inFlight[key], tracked)) _inFlight.remove(key);
      }
    }();
    _inFlight[key] = tracked;
    return tracked;
  }

  Future<Uint8List> _load(
    Uri uri,
    String key,
    Map<String, String> headers,
    bool preferPlatform,
    SourceImageLoadPriority priority,
    (int, int) epoch,
  ) async {
    final disk = await _readDisk(key);
    if (disk != null) {
      if (_isCurrent(key, epoch)) _remember(key, disk);
      return disk;
    }

    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final bytes = await _withPermit(
          () => preferPlatform
              ? _downloadWithPlatform(uri, headers)
              : headers.isEmpty
              ? _loader(uri)
              : _download(uri, headers),
          priority: priority,
        );
        _validateBytes(bytes);
        if (_isCurrent(key, epoch)) {
          _remember(key, bytes);
          await _writeDisk(key, bytes);
        }
        return bytes;
      } catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (attempt == 0 && _isTransient(error)) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Future<T> _withPermit<T>(
    Future<T> Function() action, {
    required SourceImageLoadPriority priority,
  }) async {
    await _acquirePermit(priority);
    try {
      return await action();
    } finally {
      _releasePermit();
    }
  }

  Future<void> _acquirePermit(SourceImageLoadPriority priority) async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final waiter = _SourceImageWaiter();
    final queue = priority == SourceImageLoadPriority.visible
        ? _visibleWaiters
        : _preloadWaiters;
    queue.add(waiter);
    await waiter.completer.future;
  }

  void _releasePermit() {
    final queue = _visibleWaiters.isNotEmpty
        ? _visibleWaiters
        : _preloadWaiters;
    if (queue.isNotEmpty) {
      // Transfer the occupied slot to the highest-priority waiter. Keeping
      // [_active] unchanged prevents a new request from stealing the slot.
      queue.removeFirst().completer.complete();
      return;
    }
    _active--;
  }

  Future<Uint8List> _download(
    Uri uri, [
    Map<String, String> requestHeaders = const {},
  ]) async {
    try {
      var current = uri;
      var headers = Map<String, String>.from(requestHeaders);
      for (var redirects = 0; redirects <= 5; redirects++) {
        await _networkPolicy.validate(current);
        final response = await _dio.get<ResponseBody>(
          current.toString(),
          options: Options(
            responseType: ResponseType.stream,
            headers: headers,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status >= 300) {
          await response.data?.stream.drain<void>();
          if (redirects == 5) {
            throw const SourceCoverLoadException(
              'Cover redirected too many times.',
            );
          }
          final next = BookSourceNetworkPolicy.redirectTarget(
            current,
            response.headers.value(HttpHeaders.locationHeader),
          );
          if (current.authority != next.authority) {
            headers.removeWhere((name, _) {
              final normalized = name.toLowerCase();
              return normalized == HttpHeaders.cookieHeader ||
                  normalized == HttpHeaders.authorizationHeader ||
                  normalized == 'proxy-authorization' ||
                  normalized == HttpHeaders.hostHeader;
            });
          }
          current = next;
          continue;
        }
        if (status != HttpStatus.ok || response.data == null) {
          throw SourceCoverLoadException(
            'Cover request failed with HTTP $status.',
            transient: _isTransientStatus(status),
          );
        }
        final declaredLength = int.tryParse(
          response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
        );
        if (declaredLength != null && declaredLength > maxImageBytes) {
          throw SourceCoverLoadException(
            'Cover exceeds the $maxImageBytes byte limit.',
          );
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream) {
          if (builder.length + chunk.length > maxImageBytes) {
            throw SourceCoverLoadException(
              'Cover exceeds the $maxImageBytes byte limit.',
            );
          }
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (!_hasSupportedImageSignature(bytes)) {
          throw const SourceCoverLoadException(
            'Cover response is not an image.',
          );
        }
        return bytes;
      }
      throw const SourceCoverLoadException('Cover request failed.');
    } on DioException catch (error) {
      try {
        return await _downloadWithPlatform(uri, requestHeaders);
      } catch (_) {
        throw SourceCoverLoadException(
          'Cover request failed: ${error.message ?? error.type.name}',
          transient: switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout ||
            DioExceptionType.transformTimeout ||
            DioExceptionType.connectionError ||
            DioExceptionType.unknown => true,
            DioExceptionType.badResponse => _isTransientStatus(
              error.response?.statusCode ?? 0,
            ),
            DioExceptionType.cancel || DioExceptionType.badCertificate => false,
          },
        );
      }
    }
  }

  Future<Uint8List> _downloadWithPlatform(
    Uri uri,
    Map<String, String> requestHeaders,
  ) async {
    var current = uri;
    var headers = <String, String>{
      'Accept':
          'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      'User-Agent': _sourceCoverUserAgent,
      ...requestHeaders,
    };
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      final response = await _platformLoader.loadBytes(
        url: current,
        headers: headers,
        maxBytes: maxImageBytes,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final bytes = response.bytes;
        if (!_hasSupportedImageSignature(bytes)) {
          throw const SourceCoverLoadException(
            'Cover response is not an image.',
          );
        }
        return bytes;
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        if (redirects == 5) {
          throw const SourceCoverLoadException(
            'Cover redirected too many times.',
          );
        }
        final next = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.location,
        );
        if (current.authority != next.authority) {
          headers.removeWhere((name, _) {
            final normalized = name.toLowerCase();
            return normalized == HttpHeaders.cookieHeader ||
                normalized == HttpHeaders.authorizationHeader ||
                normalized == 'proxy-authorization' ||
                normalized == HttpHeaders.hostHeader;
          });
        }
        current = next;
        continue;
      }
      throw SourceCoverLoadException(
        'Cover request failed with HTTP ${response.statusCode}.',
        transient: _isTransientStatus(response.statusCode),
      );
    }
    throw const SourceCoverLoadException('Cover request failed.');
  }

  bool _isTransient(Object error) =>
      error is SourceCoverLoadException && error.transient;

  bool _isTransientStatus(int status) =>
      status == HttpStatus.requestTimeout ||
      status == 425 ||
      status == HttpStatus.tooManyRequests ||
      status == HttpStatus.internalServerError ||
      status == HttpStatus.badGateway ||
      status == HttpStatus.serviceUnavailable ||
      status == HttpStatus.gatewayTimeout;

  void _validateUri(Uri uri) {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const SourceCoverLoadException('Invalid cover URL.');
    }
  }

  void _validateBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const SourceCoverLoadException('Cover response is empty.');
    }
    if (bytes.lengthInBytes > maxImageBytes) {
      throw SourceCoverLoadException(
        'Cover exceeds the $maxImageBytes byte limit.',
      );
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
      // A cache write must never turn a valid network image into a UI failure.
    }
  }

  Future<Directory> directory() async {
    if (_cacheDirectory != null) return _cacheDirectory;
    final root = await getApplicationCacheDirectory();
    return Directory(path.join(root.path, cacheDirectoryName));
  }

  Future<File> _fileFor(String key) async =>
      File(path.join((await directory()).path, '$key.img'));

  String _key(Uri uri, [Map<String, String> headers = const {}]) {
    final entries = headers.entries.toList()
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    return sha256
        .convert(
          utf8.encode(
            '${uri.toString()}\u0000${entries.map((entry) => '${entry.key}:${entry.value}').join('\u0001')}',
          ),
        )
        .toString();
  }

  bool _isCurrent(String key, (int, int) epoch) =>
      epoch.$1 == _cacheEpoch && epoch.$2 == (_keyEpochs[key] ?? 0);

  Future<void> evict(Uri uri, {Map<String, String> headers = const {}}) async {
    _validateUri(uri);
    final rawKey = _key(uri, headers);
    for (final key in ['default:$rawKey', 'platform:$rawKey']) {
      _keyEpochs[key] = (_keyEpochs[key] ?? 0) + 1;
      _inFlight.remove(key);
      final memory = _memory.remove(key);
      if (memory != null) _memoryBytes -= memory.lengthInBytes;
      final file = await _fileFor(key);
      if (await file.exists()) await file.delete();
    }
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

  Future<int> diskSizeBytes() async => _directorySize(await directory());

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // Ignore files removed concurrently by the OS or cache cleanup.
        }
      }
    }
    return total;
  }
}

class _SourceImageWaiter {
  final Completer<void> completer = Completer<void>();
}

bool _hasSupportedImageSignature(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return true;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return true;
  }
  if (bytes.length >= 6) {
    final signature = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
    if (signature == 'GIF87a' || signature == 'GIF89a') return true;
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return true;
  }
  return false;
}
