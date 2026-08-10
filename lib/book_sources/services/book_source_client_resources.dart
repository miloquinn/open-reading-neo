import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../protocol/book_source_protocol.dart';
import '../protocol/orsp/orsp_book_source_backend.dart';
import '../protocol/orsp/orsp_http_pipeline.dart';
import '../protocol/reading_source/reading_source_backend.dart';
import '../source_engine/source_runtime.dart';
import 'book_source_chapter_cache.dart';
import 'book_source_network_policy.dart';
import 'book_source_response_cache.dart';

class BookSourceClientResources {
  BookSourceClientResources._(
    this.orspBackend,
    this.readingBackend,
    this._dio,
    this._ownsDio,
    this._runtime,
    this._closeDio,
    this._systemDio,
    this._ownsSystemDio,
  );

  factory BookSourceClientResources.create({
    Dio? dio,
    Dio? systemDio,
    BookSourceChapterCache? chapterCache,
    BookSourceResponseCache? responseCache,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    @visibleForTesting Dio Function()? dioFactory,
    @visibleForTesting SourceRuntime? runtime,
    @visibleForTesting SourceRuntime Function()? runtimeFactory,
    @visibleForTesting OrspBookSourceBackendPort? orspBackend,
    @visibleForTesting ReadingSourceBackendPort? readingBackend,
    @visibleForTesting Future<bool> Function()? additionalProtocolsEnabled,
    @visibleForTesting void Function(Dio dio, {required bool force})? closeDio,
  }) {
    assert(dio == null || dioFactory == null);
    assert(runtime == null || runtimeFactory == null);

    final ownsDio = dio == null;
    final resolvedDio =
        dio ?? (dioFactory ?? () => _createDio(networkPolicy))();
    final ownsSystemDio = systemDio == null && dio == null;
    final resolvedSystemDio = systemDio ?? dio ?? _createSystemDio();
    final lazyRuntime = _LazyRuntime(
      injected: runtime,
      factory: runtimeFactory ?? SourceRuntime.new,
      ownsCreated: runtime == null,
    );
    final resolvedOrsp =
        orspBackend ??
        OrspBookSourceBackend(
          OrspHttpPipeline(
            resolvedDio,
            networkPolicy,
            responseCache ?? BookSourceResponseCache.instance,
            systemDio: resolvedSystemDio,
          ),
          chapterCache ?? const BookSourceChapterCache(),
        );
    final resolvedReading =
        readingBackend ??
        ReadingSourceBackend(
          lazyRuntime.get,
          additionalProtocolsEnabled: additionalProtocolsEnabled,
        );
    return BookSourceClientResources._(
      resolvedOrsp,
      resolvedReading,
      resolvedDio,
      ownsDio,
      lazyRuntime,
      closeDio ?? _defaultCloseDio,
      resolvedSystemDio,
      ownsSystemDio,
    );
  }

  final OrspBookSourceBackendPort orspBackend;
  final ReadingSourceBackendPort readingBackend;
  final Dio _dio;
  final bool _ownsDio;
  final _LazyRuntime _runtime;
  final void Function(Dio dio, {required bool force}) _closeDio;
  final Dio _systemDio;
  final bool _ownsSystemDio;
  bool _closed = false;

  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    _runtime.closeIfOwned(force: force);
    if (_ownsDio) _closeDio(_dio, force: force);
    if (_ownsSystemDio) _systemDio.close(force: force);
  }

  static Dio _createDio(BookSourceNetworkPolicy networkPolicy) =>
      Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 12),
            sendTimeout: const Duration(seconds: 8),
            headers: const {
              'Accept': 'application/json',
              'X-Open-Reading-Protocol': openReadingSourceProtocolVersion,
            },
          ),
        )
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: networkPolicy.createPinnedHttpClient,
        );

  static Dio _createSystemDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      sendTimeout: const Duration(seconds: 8),
      headers: const {
        'Accept': 'application/json',
        'X-Open-Reading-Protocol': openReadingSourceProtocolVersion,
      },
    ),
  );

  static void _defaultCloseDio(Dio dio, {required bool force}) {
    dio.close(force: force);
  }
}

class _LazyRuntime {
  _LazyRuntime({
    required SourceRuntime? injected,
    required this._factory,
    required bool ownsCreated,
  }) : _runtime = injected,
       _ownsRuntime = injected == null && ownsCreated;

  SourceRuntime? _runtime;
  final SourceRuntime Function() _factory;
  final bool _ownsRuntime;

  SourceRuntime get() => _runtime ??= _factory();

  void closeIfOwned({required bool force}) {
    if (_ownsRuntime) _runtime?.close(force: force);
  }
}
